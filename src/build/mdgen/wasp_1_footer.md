# FILES

_\$XDG_CONFIG_HOME/wasp/config.wasp_

: Location of the default configuration file.

_\$HOME/Library/Application Support/com.mitchellh.wasp/config.wasp_

: **On macOS**, location of the default configuration file. This location takes
precedence over the XDG environment locations.

_\$LOCALAPPDATA/wasp/config.wasp_

: **On Windows**, if _\$XDG_CONFIG_HOME_ is not set, _\$LOCALAPPDATA_ will be searched
for configuration files.

# ENVIRONMENT

**TERM**

: Defaults to `xterm-wasp`. Can be configured with the `term` configuration option.

**WASP_RESOURCES_DIR**

: Where the Wasp resources can be found.

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/com.mitchellh.wasp**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

**WASP_LOG**

: The `WASP_LOG` environment variable can be used to control which
destinations receive logs. Wasp currently defines two destinations:

: - `stderr` - logging to `stderr`.
: - `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

: Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `WASP_LOG` to `true` will enable all
destinations. Setting `WASP_LOG` to `false` will disable all destinations.

# BUGS

See GitHub issues: <https://github.com/wasp-org/wasp/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
Wasp contributors <https://github.com/wasp-org/wasp/graphs/contributors>

# SEE ALSO

**wasp(5)**
