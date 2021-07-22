# Keep overflow, bounds, and assertion checks in release builds. Archive
# metadata is input, and -d:danger would remove important rejection paths.
switch("path", "src")
switch("path", "tests")
switch("mm", "orc")
switch("warningAsError", "UnusedImport")
switch("overflowChecks", "on")
switch("boundChecks", "on")
switch("assertions", "on")
