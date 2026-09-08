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
import java.util.Set;

/** Minimal NoMount-owned filter for Android's central package-visibility gate. */
final class AppCloak {
    private static final String TAG = "NoMount-AppCloak";
    private static final File POLICY = new File("/data/system/nomount_appcloak/hidden_apps.conf");
    private static final File ACTIVE = new File("/data/system/nomount_appcloak/active");
    private static volatile Set<String> hidden = Collections.emptySet();
    private static volatile long policyStamp = Long.MIN_VALUE;
    private static volatile long checkedAt;

    private AppCloak() {}

    static void start() {
        Thread worker = new Thread(() -> {
            try {
                waitForPackageManager();
                install();
                markActive();
                Log.i(TAG, "package visibility filter installed");
            } catch (Throwable t) {
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
        Method loaderMethod = Class.forName("com.android.internal.os.ZygoteInit")
                .getDeclaredMethod("getOrCreateSystemServerClassLoader");
        loaderMethod.setAccessible(true);
        ClassLoader loader = (ClassLoader) loaderMethod.invoke(null);
        Class<?> filter = Class.forName("com.android.server.pm.AppsFilterImpl", true, loader);
        int count = 0;
        for (Executable method : Reflection.getHiddenExecutables(filter)) {
            if (!(method instanceof Method) || !"shouldFilterApplication".equals(method.getName())
                    || ((Method) method).getReturnType() != boolean.class)
                continue;
            Hooks.hook(method, Hooks.EntryPointType.DIRECT,
                    (MethodHandle original, EmulatedStackFrame frame) -> dispatch(original, frame),
                    Hooks.EntryPointType.DIRECT);
            count++;
        }
        if (count == 0) throw new NoSuchMethodException("AppsFilterImpl.shouldFilterApplication");
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

    private static void dispatch(MethodHandle original, EmulatedStackFrame frame) throws Throwable {
        try {
            int callerUid = intArgument(frame, 2);
            Object targetState = referenceArgument(frame, 4);
            String target = packageName(targetState);
            if (callerUid >= 10000 && target != null && isHidden(target)
                    && !callerOwnsTarget(frame, callerUid, target)) {
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

    private static boolean callerOwnsTarget(EmulatedStackFrame frame, int uid, String target) {
        try {
            Object computer = referenceArgument(frame, 1);
            Method m = computer.getClass().getMethod("getPackagesForUid", int.class);
            m.setAccessible(true);
            String[] packages = (String[]) m.invoke(computer, uid);
            if (packages != null) for (String p : packages) if (target.equals(p)) return true;
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
