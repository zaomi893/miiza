package io.github.cvhhji.nomount.appcloak;

import android.os.FileObserver;
import android.os.SystemClock;
import android.util.Log;

import com.v7878.unsafe.invoke.EmulatedStackFrame;
import com.v7878.unsafe.invoke.Transformers;
import com.v7878.vmtools.Hooks;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileWriter;
import java.io.FileReader;
import java.lang.invoke.MethodHandle;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/** Minimal NoMount-owned filter for Android's central package-visibility gate. */
final class AppCloak {
    private static final String TAG = "NoMount-AppCloak";
    private static final File POLICY = new File("/data/system/nomount_appcloak/hidden_apps.conf");
    private static final File SCOPE_POLICY = new File("/data/system/nomount_appcloak/scope_apps.conf");
    private static final File ACTIVE = new File("/data/system/nomount_appcloak/active");
    private static final File STATUS = new File("/data/system/nomount_appcloak/status");
    private static volatile Set<String> hidden = Collections.emptySet();
    private static volatile Set<String> scoped = Collections.emptySet();
    private static volatile long policyStamp = Long.MIN_VALUE;
    private static volatile long policyGeneration;
    private static volatile long checkedAt = -10_000L;
    private static volatile String phase = "init";
    private static final long POLICY_FALLBACK_INTERVAL_MS = 300_000L;
    private static final long POLICY_EVENT_DEBOUNCE_MS = 250L;
    private static final long CALLER_CACHE_TTL_MS = 300_000L;
    private static final Object POLICY_WATCH_LOCK = new Object();
    private static boolean policyEventPending;
    private static long policyEventAt = Long.MIN_VALUE;
    private static final ConcurrentHashMap<Integer, CallerPolicy> callerCache =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Class<?>, Method> packageNameMethods =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Class<?>, Field> packageNameFields =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Class<?>, Method> appIdMethods =
            new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<Class<?>, Method> packagesForUidMethods =
            new ConcurrentHashMap<>();

    private static final class CallerPolicy {
        final boolean hidden;
        final boolean scoped;
        final long generation;
        final long expiresAt;

        CallerPolicy(boolean hidden, boolean scoped, long generation, long expiresAt) {
            this.hidden = hidden;
            this.scoped = scoped;
            this.generation = generation;
            this.expiresAt = expiresAt;
        }
    }

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
                watchPolicyChanges();
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
        Set<Method> gates = new LinkedHashSet<>();
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
                    Collections.addAll(gates, type.getDeclaredMethods());
                    type = type.getSuperclass();
                }
            } catch (Throwable t) {
                Log.w(TAG, "skipping AppsFilter candidate " + name, t);
            }
        }
        int count = 0;
        for (Method method : gates) {
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

    private static void watchPolicyChanges() {
        File directory = POLICY.getParentFile();
        int events = FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO
                | FileObserver.DELETE | FileObserver.ATTRIB;
        FileObserver observer = new FileObserver(directory, events) {
            @Override
            public void onEvent(int event, String path) {
                if (!"hidden_apps.conf".equals(path) && !"scope_apps.conf".equals(path)) return;
                synchronized (POLICY_WATCH_LOCK) {
                    policyEventPending = true;
                    policyEventAt = SystemClock.uptimeMillis();
                    POLICY_WATCH_LOCK.notifyAll();
                }
            }
        };
        Thread watcher = new Thread(() -> {
            observer.start();
            try {
                while (true) {
                    long now = SystemClock.uptimeMillis();
                    long fallbackAt = checkedAt + POLICY_FALLBACK_INTERVAL_MS;
                    long waitMs = policyEventPending
                            ? Math.max(0L, policyEventAt + POLICY_EVENT_DEBOUNCE_MS - now)
                            : Math.max(1L, fallbackAt - now);
                    if (waitMs > 0L) {
                        synchronized (POLICY_WATCH_LOCK) {
                            if (!policyEventPending) {
                                POLICY_WATCH_LOCK.wait(Math.min(waitMs, POLICY_FALLBACK_INTERVAL_MS));
                                continue;
                            } else {
                                POLICY_WATCH_LOCK.wait(waitMs);
                                continue;
                            }
                        }
                    }
                    synchronized (POLICY_WATCH_LOCK) {
                        if (!policyEventPending
                                && SystemClock.uptimeMillis() < checkedAt + POLICY_FALLBACK_INTERVAL_MS) {
                            continue;
                        }
                        policyEventPending = false;
                    }
                    forceReload();
                }
            } catch (Throwable t) {
                observer.stop();
                Log.w(TAG, "policy watcher stopped; falling back to lazy checks", t);
            }
        }, "NoMount-AppCloak-Policy");
        watcher.setDaemon(true);
        watcher.start();
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
            int callerAppId = callerUid % 100000;
            CallerPolicy caller = callerAppId >= 10000
                    ? callerPolicy(frame, callerUid, snapshotIndex) : null;
            if (caller != null && caller.hidden) {
                // A hidden caller sees the complete package set, including
                // other members of the hidden group.
                frame.accessor().setBoolean(EmulatedStackFrame.RETURN_VALUE_IDX, false);
                return;
            }
            // Most callers are outside the configured scope. Return to the original
            // gate before reflecting on the target package in that overwhelmingly
            // common path.
            if (caller == null || !caller.scoped) {
                Transformers.invokeExactNoChecks(original, frame);
                return;
            }
            Object targetState = referenceArgument(frame, targetIndex);
            String target = packageName(targetState);
            if (target != null && hidden.contains(target)
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
            Class<?> type = targetState.getClass();
            Method appId = appIdMethods.get(type);
            if (appId == null) {
                appId = type.getMethod("getAppId");
                appId.setAccessible(true);
                appIdMethods.put(type, appId);
            }
            Object value = appId.invoke(targetState);
            if (value instanceof Integer && uid % 100000 == (Integer) value) return true;
        } catch (Throwable ignored) {}
        try {
            if (snapshotIndex < 0) return false;
            Object computer = referenceArgument(frame, snapshotIndex);
            Class<?> computerType = computer.getClass();
            Method m = packagesForUidMethods.get(computerType);
            if (m == null) {
                m = computerType.getMethod("getPackagesForUid", int.class);
                m.setAccessible(true);
                packagesForUidMethods.put(computerType, m);
            }
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
    private static String[] packagesForUid(EmulatedStackFrame frame, int uid,
            int snapshotIndex) {
        if (snapshotIndex < 0) return null;
        try {
            Object computer = referenceArgument(frame, snapshotIndex);
            if (computer == null) return null;
            Class<?> type = computer.getClass();
            Method m = packagesForUidMethods.get(type);
            if (m == null) {
                m = type.getMethod("getPackagesForUid", int.class);
                m.setAccessible(true);
                packagesForUidMethods.put(type, m);
            }
            return (String[]) m.invoke(computer, uid);
        } catch (Throwable ignored) {}
        return null;
    }

    private static CallerPolicy callerPolicy(EmulatedStackFrame frame, int uid,
            int snapshotIndex) {
        reloadIfNeeded();
        long now = SystemClock.uptimeMillis();
        long generation = policyGeneration;
        CallerPolicy cached = callerCache.get(uid);
        if (cached != null && cached.generation == generation && now < cached.expiresAt)
            return cached;
        boolean isHidden = false;
        boolean isScoped = false;
        String[] packages = packagesForUid(frame, uid, snapshotIndex);
        if (packages != null) {
            Set<String> hiddenSnapshot = hidden;
            Set<String> scopedSnapshot = scoped;
            for (String pkg : packages) {
                isHidden |= hiddenSnapshot.contains(pkg);
                isScoped |= scopedSnapshot.contains(pkg);
                if (isHidden && isScoped) break;
            }
        }
        CallerPolicy result = new CallerPolicy(isHidden, isScoped, generation,
                now + CALLER_CACHE_TTL_MS);
        callerCache.put(uid, result);
        return result;
    }

    private static String packageName(Object state) {
        if (state == null) return null;
        try {
            Class<?> type = state.getClass();
            Method m = packageNameMethods.get(type);
            if (m == null) {
                m = type.getMethod("getPackageName");
                m.setAccessible(true);
                packageNameMethods.put(type, m);
            }
            return (String) m.invoke(state);
        } catch (Throwable ignored) {}
        for (String fieldName : new String[]{"mName", "name"}) {
            try {
                Class<?> type = state.getClass();
                Field f = packageNameFields.get(type);
                if (f == null || !fieldName.equals(f.getName())) {
                    f = type.getDeclaredField(fieldName);
                    f.setAccessible(true);
                    packageNameFields.put(type, f);
                }
                Object value = f.get(state);
                if (value instanceof String) return (String) value;
            } catch (Throwable ignored) {}
        }
        return null;
    }

    private static void reloadIfNeeded() {
        long now = SystemClock.uptimeMillis();
        if (now - checkedAt >= POLICY_FALLBACK_INTERVAL_MS) reload(now);
    }

    private static void forceReload() {
        synchronized (AppCloak.class) {
            checkedAt = -POLICY_FALLBACK_INTERVAL_MS;
            reload(SystemClock.uptimeMillis());
        }
    }

    private static synchronized void reload(long now) {
        if (now - checkedAt < 0L) return;
        checkedAt = now;
        long hiddenStamp = POLICY.exists() ? POLICY.lastModified() ^ POLICY.length() : Long.MIN_VALUE;
        long scopeStamp = SCOPE_POLICY.exists()
                ? SCOPE_POLICY.lastModified() ^ SCOPE_POLICY.length() : Long.MIN_VALUE;
        long stamp = hiddenStamp * 31L + scopeStamp;
        if (stamp == policyStamp) return;
        Set<String> nextHidden = readPolicy(POLICY);
        Set<String> nextScoped = readPolicy(SCOPE_POLICY);
        hidden = Collections.unmodifiableSet(nextHidden);
        scoped = Collections.unmodifiableSet(nextScoped);
        policyStamp = stamp;
        policyGeneration++;
        callerCache.clear();
        Log.i(TAG, "loaded " + nextHidden.size() + " hidden target(s), "
                + nextScoped.size() + " scoped caller(s)");
    }

    private static Set<String> readPolicy(File file) {
        Set<String> next = new HashSet<>();
        try (BufferedReader in = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = in.readLine()) != null) {
                line = line.trim();
                if (line.matches("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+")) next.add(line);
            }
        } catch (Throwable ignored) {}
        return next;
    }
}
