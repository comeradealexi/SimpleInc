# SimpleInc
Simple Incremental build tool. Run any command via SimpleInc and it will track all inputs and outputs and only run your command when needed.

# How it works
SimpleInc relies on a program called Tracker.exe which is included as part of your Visual Studio install. Tracker.exe is a special tool which tracks all file access when running your command line and writes out this information.

We expand on this by also writing out the last modified timestamp of the files accessed so we know when a given command line needs to be run based on whether any of the input files have changed.


# How to use


# Building


# Limitations
