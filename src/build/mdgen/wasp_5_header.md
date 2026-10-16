% WASP(5) Version @@VERSION@@ | Wasp terminal emulator configuration file

# NAME

**wasp** - Wasp terminal emulator configuration file

# DESCRIPTION

To configure Wasp, you must use a configuration file. GUI-based configuration
is on the roadmap but not yet supported. The configuration file must be placed
at `$XDG_CONFIG_HOME/wasp/config.wasp`, which defaults to `~/.config/wasp/config.wasp`
if the [XDG environment is not set](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html).

**If you are using macOS, the configuration file can also be placed at
`$HOME/Library/Application Support/com.mitchellh.wasp/config.wasp`.** This is the
default configuration location for macOS. It will be searched before any of the
XDG environment locations listed above.

The file format is documented below as an example:

    # The syntax is "key = value". The whitespace around the equals doesn't matter.
    background = 282c34
    foreground= ffffff

    # Blank lines are ignored!

    keybind = ctrl+z=close_surface
    keybind = ctrl+d=new_split:right

    # Colors can be changed by setting the 16 colors of `palette`, which each color
    # being defined as regular and bold.
    #
    # black
    palette = 0=#1d2021
    palette = 8=#7c6f64
    # red
    palette = 1=#cc241d
    palette = 9=#fb4934
    # green
    palette = 2=#98971a
    palette = 10=#b8bb26
    # yellow
    palette = 3=#d79921
    palette = 11=#fabd2f
    # blue
    palette = 4=#458588
    palette = 12=#83a598
    # purple
    palette = 5=#b16286
    palette = 13=#d3869b
    # aqua
    palette = 6=#689d6a
    palette = 14=#8ec07c
    # white
    palette = 7=#a89984
    palette = 15=#fbf1c7

You can view all available configuration options and their documentation by
executing the command `wasp +show-config --default --docs`. Note that this will
output the full default configuration with docs to stdout, so you may want to
pipe that through a pager, an editor, etc.

Note: You'll see a lot of weird blank configurations like `font-family =`. This
is a valid syntax to specify the default behavior (no value). The `+show-config`
outputs it so it's clear that key is defaulting and also to have something to
attach the doc comment to.

You can also see and read all available configuration options in the source
Config structure. The available keys are the keys verbatim, and their possible
values are typically documented in the comments. You also can search for
the public config files of many Wasp users for examples and inspiration.

## Configuration Errors

If your configuration file has any errors, Wasp does its best to ignore
them and move on. Configuration errors will be logged.

## Debugging Configuration

You can verify that configuration is being properly loaded by looking at the
debug output of Wasp.

In the debug output, you should see in the first 20 lines or so messages about
loading (or not loading) a configuration file, as well as any errors it may have
encountered. Configuration errors are also shown in a dedicated window on both
macOS and Linux (GTK). Wasp does not treat configuration errors as fatal and
will fall back to default values for erroneous keys.

You can also view the full configuration Wasp is loading using `wasp
+show-config` from the command-line. Use the `--help` flag to additional options
for that command.

## Logging

Wasp can write logs to a number of destinations. On all platforms, logging to
`stderr` is available. Depending on the platform and how Wasp was launched,
logs sent to `stderr` may be stored by the system and made available for later
retrieval.

On Linux if Wasp is launched by the default `systemd` user service, you can use
`journald` to see Wasp's logs: `journalctl --user --unit app-com.mitchellh.wasp.service`.

On macOS logging to the macOS unified log is available and enabled by default.
--Use the system `log` CLI to view Wasp's logs: `sudo log stream --level debug
--predicate 'subsystem=="com.mitchellh.wasp"'`.

Wasp's logging can be configured in two ways. The first is by what
optimization level Wasp is compiled with. If Wasp is compiled with `Debug`
optimizations debug logs will be output to `stderr`. If Wasp is compiled with
any other optimization the debug logs will not be output to `stderr`.

Wasp also checks the `WASP_LOG` environment variable. It can be used
to control which destinations receive logs. Wasp currently defines two
destinations:

- `stderr` - logging to `stderr`.
- `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `WASP_LOG` to `true` will enable all
destinations. Setting `WASP_LOG` to `false` will disable all destinations.
