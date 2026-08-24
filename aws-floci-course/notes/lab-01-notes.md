# Lab 01 Notes

## Step 7 — Think about it

**Q: If `--persist` mounts a directory correctly, why is the directory almost empty in `memory` mode?**

Mounting a host directory only gives Floci a *place* to write; it does not tell Floci *to* write there. `FLOCI_STORAGE_MODE` is a separate variable that controls durability, and its default is `memory`, under which Floci keeps state in RAM and treats it as disposable — so almost nothing gets flushed to the mounted directory regardless of whether the mount itself is correct. Because Floci also assumes its own state is throwaway in this mode, it deletes the Docker volumes it created on teardown, which is why a correctly mounted directory still looks empty and a "new" volume appears on every restart.
