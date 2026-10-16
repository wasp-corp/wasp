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

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/com.mitchellh.wasp**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

# BUGS

See GitHub issues: <https://github.com/wasp-org/wasp/issues>

# AUTHOR

Mitchell Hashimoto <m@mitchellh.com>
Wasp contributors <https://github.com/wasp-org/wasp/graphs/contributors>

# SEE ALSO

**wasp(1)**
