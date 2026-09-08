package io.github.cvhhji.nomount.appcloak;

import android.os.SystemClock;
import android.util.Log;

import com.v7878.unsafe.Reflection;
import com.v7878.unsafe.invoke.EmulatedStackFrame;
import com.v7878.unsafe.invoke.Transformers;
import com.v7878.vmtools.Hooks;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileWriter;
import java.io.FileReader;
import java.lang.invoke.MethodHandle;
import java.lang.reflect.Executable;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Set;

/** Minimal NoMount-owned filter for Android's central package-visibility gate. */
final class AppCloak {
    private static final String TAG = "NoMount-AppCloak";
    private static final File POLICY = new File("/data/system/nomount_appcloak/hidden_apps.conf");
    private static final File ACTIVE = new File("/data/system/nomount_appcloak/active");
    private static final File STATUS = new File("/data/system/nomount_appcloak/status");
    private static volatile Set<String> hidden = Collections.emptySet();
    private static volatile long policyStamp = Long.MIN_VALUE;
    private static volatile long checkedAt;
    private static volatile String phase = "init";

    private AppCloak() {}

    static void start() {
        publishStatus("entrypoint");
        Thread worker = new Thread(() -> {
            try {
                publishStatus("waiting-pm");
                waitForPackageManager();
                publishStatus("installing");
                install();
                markActive();
                publishStatus("active");
                Log.i(TAG, "package visibility filter installed");
            } catch (Throwable t) {
                String where = t.getStackTrace().length == 0 ? "unknown"
                        : t.getStackTrace()[0].getClassName() + "_"
                        + t.getStackTrace()[0].getMethodName() + "_"
                        + t.getStackTrace()[0].getLineNumber();
                publishStatus("failed:" + phase + ":" + t.getClass().getSimpleName()
                        + ":" + String.valueOf(t.getMessage()) + ":" + where);
                Log.e(TAG, "filter install failed", t);
            }
        }, "NoMount-AppCloak");
        worker.setDaemon(true);
        worker.start();
    }

    private static void waitForPackageManager() throws Throwable {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        Method checkService = serviceManager.getDeclaredMethod("checkService", String.class);
        checkService.setAccessible(true);
        long deadline = SystemClock.uptimeMillis() + 120_000L;
        while (checkService.invoke(null, "package") == null) {
            if (SystemClock.uptimeMillis() >= deadline)
                throw new IllegalStateException("PackageManager did not become ready");
            Thread.sleep(250L);
        }
    }

    private static void install() throws Throwable {
        publishStatus("install:loader");
        Method loaderMethod = Class.forName("com.android.internal.os.ZygoteInit")
                .getDeclaredMethod("getOrCreateSystemServerClassLoader");
        loaderMethod.setAccessible(true);
        ClassLoader loader = (ClassLoader) loaderMethod.invoke(null);
        Set<Executable> gates = new LinkedHashSet<>();
        String[] candidates = {
                "com.android.server.pm.AppsFilterImpl",
                "com.android.server.pm.AppsFilterBase",
                "com.android.server.pm.AppsFilterLocked",
                "com.android.server.pm.AppsFilterSnapshotImpl"
        };
        for (String name : candidates) {
            try {
                publishStatus("install:scan:" + name.substring(name.lastIndexOf('.') + 1));
                Class<?> type = Class.forName(name, false, loader);
                while (type != null && type != Object.class) {
                    Collections.addAll(gates, Reflection.getHiddenExecutables(type));
                    type = type.getSuperclass();
                }
            } catch (Throwable t) {
                Log.w(TAG, "skipping AppsFilter candidate " + name, t);
            }
        }
        int count = 0;
        for (Executable executable : gates) {
            if (!(executable instanceof Method)) continue;
            Method method = (Method) executable;
            if (!"shouldFilterApplication".equals(method.getName())
                    || method.getReturnType() != boolean.class) continue;
            int callerIndex = -1, targetIndex = -1, snapshotIndex = -1;
            Class<?>[] params = method.getParameterTypes();
            for (int i = 0; i < params.length; i++) {
                String name = params[i].getName();
                if (callerIndex < 0 && params[i] == int.class) callerIndex = i + 1;
                if (name.endsWith("PackageStateInternal")) targetIndex = i + 1;
                if (snapshotIndex < 0 && (name.endsWith("PackageDataSnapshot")
                        || name.endsWith("Computer"))) snapshotIndex = i + 1;
            }
            if (callerIndex < 0 || targetIndex < 0) continue;
            final int caller = callerIndex;
            final int target = targetIndex;
            final int snapshot = snapshotIndex;
            publishStatus("install:hook:" + method.getDeclaringClass().getSimpleName());
            Hooks.hook(method, Hooks.EntryPointType.DIRECT,
                    (MethodHandle original, EmulatedStackFrame frame) ->
                            dispatch(original, frame, caller, target, snapshot),
                    Hooks.EntryPointType.DIRECT);
            count++;
        }
        if (count == 0) throw new NoSuchMethodException("AppsFilter*.shouldFilterApplication");
        Log.i(TAG, "hooked " + count + " package visibility gate(s)");
    }

    private static void markActive() {
        try (FileWriter out = new FileWriter(ACTIVE, false)) {
            out.write(Long.toString(System.currentTimeMillis()));
            out.write('\n');
        } catch (Throwable t) {
            Log.w(TAG, "unable to publish active marker", t);
        }
    }

    private static void publishStatus(String value) {
        phase = value;
        try (FileWriter out = new FileWriter(STATUS, false)) {
            out.write(value.replaceAll("[^A-Za-z0-9:_-]", "_"));
            out.write('\n');
        } catch (Throwable ignored) {}
    }

    private static void dispatch(MethodHandle original, EmulatedStackFrame frame,
            int callerIndex, int targetIndex, int snapshotIndex) throws Throwable {
        try {
            int callerUid = intArgument(frame, callerIndex);
            Object targetState = referenceArgument(frame, targetIndex);
            String target = packageName(targetState);
            int callerAppId = callerUid % 100000;
            if (callerAppId >= 10000
                    && callerIsHidden(frame, callerUid, snapshotIndex)) {
                // A hidden caller sees the complete package set, including
                // other members of the hidden group.
                frame.accessor().setBoolean(EmulatedStackFrame.RETURN_VALUE_IDX, false);
                return;
            }
            if (callerAppId >= 10000 && target != null && isHidden(target)
                    && !callerOwnsTarget(frame, callerUid, targetState, target,
                            snapshotIndex)) {
                frame.accessor().setBoolean(EmulatedStackFrame.RETURN_VALUE_IDX, true);
                return;
            }
        } catch (Throwable t) {
            // Fail open: a vendor signature change must never break PackageManager.
            Log.w(TAG, "filter call failed open", t);
        }
        Transformers.invokeExactNoChecks(original, frame);
    }

    private static int intArgument(EmulatedStackFrame frame, int index) {
        return frame.accessor().getInt(index);
    }

    private static Object referenceArgument(EmulatedStackFrame frame, int index) {
        return frame.accessor().getReference(index);
    }

    private static boolean callerOwnsTarget(EmulatedStackFrame frame, int uid,
            Object targetState, String target, int snapshotIndex) {
        try {
            Method appId = targetState.getClass().getMethod("getAppId");
            appId.setAccessible(true);
            Object value = appId.invoke(targetState);
            if (value instanceof Integer && uid % 100000 == (Integer) value) return true;
        } catch (Throwable ignored) {}
        try {
            if (snapshotIndex < 0) return false;
            Object computer = referenceArgument(frame, snapshotIndex);
            Method m = computer.getClass().getMethod("getPackagesForUid", int.class);
            m.setAccessible(true);
            String[] packages = (String[]) m.invoke(computer, uid);
            if (packages != null) for (String p : packages) if (target.equals(p)) return true;
        } catch (Throwable ignored) {}
        return false;
    }

    /**
     * Hidden applications form a one-way-visible group: each hidden caller can
     * still enumerate every package, while ordinary callers cannot enumerate
     * any member of the hidden group.
     */
    private static boolean callerIsHidden(EmulatedStackFrame frame, int uid,
            int snapshotIndex) {
        if (snapshotIndex < 0) return false;
        try {
            Object computer = referenceArgument(frame, snapshotIndex);
            if (computer == null) return false;
            Method m = computer.getClass().getMethod("getPackagesForUid", int.class);
            m.setAccessible(true);
            String[] packages = (String[]) m.invoke(computer, uid);
            if (packages != null) {
                for (String pkg : packages) if (isHidden(pkg)) return true;
            }
        } catch (Throwable ignored) {}
        return false;
    }

    private static String packageName(Object state) {
        if (state == null) return null;
        try {
            Method m = state.getClass().getMethod("getPackageName");
            m.setAccessible(true);
            return (String) m.invoke(state);
        } catch (Throwable ignored) {}
        for (String fieldName : new String[]{"mName", "name"}) {
            try {
                Field f = state.getClass().getDeclaredField(fieldName);
                f.setAccessible(true);
                Object value = f.get(state);
                if (value instanceof String) return (String) value;
            } catch (Throwable ignored) {}
        }
        return null;
    }

    private static boolean isHidden(String pkg) {
        long now = SystemClock.uptimeMillis();
        if (now - checkedAt >= 1000) reload(now);
        return hidden.contains(pkg);
    }

    private static synchronized void reload(long now) {
        if (now - checkedAt < 1000) return;
        checkedAt = now;
        long stamp = POLICY.exists() ? POLICY.lastModified() ^ POLICY.length() : Long.MIN_VALUE;
        if (stamp == policyStamp) return;
        Set<String> next = new HashSet<>();
        try (BufferedReader in = new BufferedReader(new FileReader(POLICY))) {
            String line;
            while ((line = in.readLine()) != null) {
                line = line.trim();
                if (line.matches("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+")) next.add(line);
            }
        } catch (Throwable ignored) {}
        hidden = Collections.unmodifiableSet(next);
        policyStamp = stamp;
        Log.i(TAG, "loaded " + next.size() + " hidden package(s)");
    }
}
