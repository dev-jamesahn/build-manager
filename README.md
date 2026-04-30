# GCT Build Manager

Interactive shell menu for launching and monitoring GCT build tasks.

## Install

Clone this repository under `~/gct-build-tools/manager`, then keep convenient run paths as symlinks:

```bash
ln -sfn ~/gct-build-tools/manager/gct_build_manager.sh ~/gct_build_manager.sh
ln -sfn ~/gct-build-tools/manager/gct_build_manager.sh ~/bin/gct_build_manager
chmod +x ~/gct-build-tools/manager/gct_build_manager.sh
```

## Run

```bash
~/bin/gct_build_manager
```

Runtime data, cloned source repositories, logs, and task state are kept under `~/gct_workspace` by default.
