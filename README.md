# check_by_zabbix

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Monitoring](https://img.shields.io/badge/Monitoring-Icinga%2FNagios-blue.svg)](https://icinga.com/)
[![Version](https://img.shields.io/badge/version-1.0.2-orange.svg)](CHANGELOG.md)

An Icinga/Nagios plugin that queries the Zabbix JSON-RPC API and reports the worst active trigger severity as a standard monitoring exit code — the Zabbix equivalent of `check_by_checkmk`. Compatible with Zabbix 5.x, 6.x, and 7.x+.

## Features

- **True Problem Detection**: Uses `problem.get` as the source of truth — matches exactly what the Zabbix Problems view shows, including problems that require manual close (trigger expression may already be false while the event is still open)
- **Multi-Version Support**: Handles Zabbix 5.x/6.x (`"auth"` in JSON body) and 7.x+ (`Authorization: Bearer` header) automatically
- **Flexible Authentication**: Static API token (preferred, no session overhead) or username + password with automatic session logout on exit
- **Host Resolution**: Looks up hosts by technical name, display name, or substring search — works regardless of how the host is named in Zabbix
- **Pattern Filtering**: Include or exclude triggers by name or output/comments text using exact names, shell wildcards (`CPU*`), or regular expressions (`/^Filesystem \/.*/`)
- **Severity Thresholds**: Configurable minimum severity for WARNING and CRITICAL — map Zabbix severities to Icinga states as needed
- **Skip Options**: Suppress dependent triggers, acknowledged problems, suppressed (maintenance) triggers, and unsupported items (state=1)
- **Perfdata**: Basic counts always included; optional per-trigger severity values with include/exclude filters for perfdata
- **Verbose Mode**: Per-trigger status lines sorted by severity; optionally include trigger comments

## Prerequisites

- **bash** (4.0 or higher)
- **curl** (for API communication)
- **jq** (for JSON parsing)

### Installation on Different Platforms

**Ubuntu/Debian:**
```bash
sudo apt-get install curl jq
```

**RHEL/CentOS/Rocky Linux:**
```bash
sudo dnf install curl jq
```

**Gentoo:**
```bash
sudo emerge net-misc/curl app-misc/jq
```

## Installation

1. **Download the script:**
   ```bash
   wget https://raw.githubusercontent.com/ascii42/check_by_zabbix/main/check_by_zabbix.sh
   ```

2. **Make the script executable:**
   ```bash
   chmod +x check_by_zabbix.sh
   ```

3. **Copy to your monitoring plugins directory:**
   ```bash
   # For Icinga2
   sudo cp check_by_zabbix.sh /usr/lib/nagios/plugins/

   # For Nagios
   sudo cp check_by_zabbix.sh /usr/local/nagios/libexec/
   ```

## Usage

### Basic Syntax

```bash
./check_by_zabbix.sh -h <zabbix-hostname> -H <server-url> [options]
```

### Authentication

| Method | Parameters | Description |
|--------|-----------|-------------|
| API token | `-a <token>` | Recommended — create a persistent token in Zabbix UI: Administration › General › API tokens (Zabbix 5.4+) |
| User/password | `-u <user> -p <pass>` | Session-based login; session is logged out automatically on exit |

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-h, --host <name>` | Hostname to check (Zabbix technical name or display name) |
| `-H, --server-url <url>` | Zabbix base URL (e.g. `http://zabbix.example.com`) |

### All Options

| Option | Default | Description |
|--------|---------|-------------|
| `-h, --host <name>` | — | Zabbix host name or display name to check |
| `-H, --server-url <url>` | — | Zabbix base URL |
| `-u, --user <name>` | — | Zabbix username (triggers session-based login) |
| `-p, --password <pass>` | — | Zabbix password (use with `--user`) |
| `-a, --api-token <token>` | — | Persistent API token (bypasses session login) |
| `--api-path <path>` | `/zabbix/api_jsonrpc.php` | Path to the JSON-RPC endpoint |
| `-V, --verify-tls` | false | Verify TLS certificates (default: disabled) |
| `-v, --verbose` | false | Print individual trigger status lines |
| `-D, --debug` | false | Show detailed debug information on stderr |
| `-d, --detail` | false | Include trigger comments in verbose output |
| `-P, --perfdata` | false | Add extended per-trigger performance data |
| `-O, --perfdata-only` | false | Print only performance data (no status message) |
| `--warn-severity <level>` | `2` (warning) | Minimum Zabbix severity for WARNING exit |
| `--crit-severity <level>` | `3` (average) | Minimum Zabbix severity for CRITICAL exit |
| `--skip-dependent` | false | Skip dependent triggers (Zabbix-side filter) |
| `--skip-acknowledged` | false | Skip triggers with an acknowledged active problem |
| `--skip-suppressed` | false | Skip triggers in active maintenance/suppression |
| `--skip-unsupported` | false | Skip triggers with state=1 (item not supported or not enough data) |

### Filter Options

| Option | Description |
|--------|-------------|
| `-e, --exclude <patterns>` | Exclude triggers by name (comma-separated) |
| `-E, --exclude-output <patterns>` | Exclude triggers by description/comments text (comma-separated) |
| `-i, --include <patterns>` | Include ONLY triggers matching name patterns |
| `-I, --include-output <patterns>` | Include ONLY triggers matching description/comments patterns |
| `-j, --include-perfdata <patterns>` | Include ONLY these triggers in perfdata |
| `-g, --exclude-perfdata <patterns>` | Exclude these triggers from perfdata |

Patterns support three forms:

| Form | Example | Matches |
|------|---------|---------|
| Exact | `"High CPU usage"` | Exact string match |
| Wildcard | `"CPU*"` | Shell glob (`*` and `?`) |
| Regex | `"/^Filesystem \/.*/"` | Full POSIX extended regex between `/` delimiters |

### Severity Levels

| Name | Number | Maps to |
|------|--------|---------|
| `not_classified` | 0 | Below WARNING threshold → OK |
| `information` | 1 | Below WARNING threshold → OK |
| `warning` | 2 | Default WARNING threshold |
| `average` | 3 | Default CRITICAL threshold |
| `high` | 4 | CRITICAL |
| `disaster` | 5 | CRITICAL |

Use severity names or numbers interchangeably with `--warn-severity` / `--crit-severity`.

## Examples

### Basic Check with API Token
```bash
./check_by_zabbix.sh -h "web-prod-01" -H http://zabbix.example.com -a my_api_token
```

### Username/Password Login
```bash
./check_by_zabbix.sh -h "web-prod-01" -H http://zabbix.example.com -u Admin -p zabbix
```

### Verbose Output with Trigger Details
```bash
./check_by_zabbix.sh -h "web-prod-01" -H http://zabbix.example.com -a my_token -v -d
```

### Custom Severity Thresholds
Alert WARNING on `average` and CRITICAL only on `high` or `disaster`:
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token \
  --warn-severity average --crit-severity high
```

### Include Only CPU and Memory Triggers
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token \
  -i "CPU*,Memory*" -v
```

### Exclude Noisy or Irrelevant Triggers
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token \
  -e "vmware*,/^Zabbix agent.*/"
```

### Skip Acknowledged and Suppressed Problems
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token \
  --skip-acknowledged --skip-suppressed
```

### Non-Default API Path (Zabbix installed at root)
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token \
  --api-path /api_jsonrpc.php
```

### Extended Perfdata for Selected Triggers
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token \
  -P -j "CPU*,Memory*"
```

### Perfdata Only (for external data collection)
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token -O
```

## Sample Output

Normal check (no active problems):
```
[OK] - all 24 triggers OK | total=24 ok=24 warning=0 critical=0 unknown=0
```

With active problems:
```
[CRITICAL] - 1 critical, 2 warning, 0 unknown (24 triggers) | total=24 ok=21 warning=2 critical=1 unknown=0
```

With `--verbose`:
```
[CRITICAL] - 1 critical, 2 warning, 0 unknown (24 triggers) | total=24 ok=21 warning=2 critical=1 unknown=0
[CRITICAL]: Disk space is low on /var [high]
[WARNING]: High CPU utilization [average]
[WARNING]: Interface eth0: Link down [warning]
[OK]: MySQL is running [not_classified]
```

With `--verbose --detail`:
```
[CRITICAL]: Disk space is low on /var [high] - Less than 10% free disk space on volume /var
[WARNING]: High CPU utilization [average] - CPU load exceeds 80% for more than 5 minutes
```

With `--perfdata`:
```
[OK] - all 24 triggers OK | total=24 ok=24 warning=0 critical=0 unknown=0 High_CPU_utilization=0;1;2 Disk_space_is_low_on__var=0;1;2
```

## Integration with Monitoring Systems

### Icinga2 Configuration

Create a command definition in `/etc/icinga2/conf.d/commands.conf`:

```icinga2
object CheckCommand "check_by_zabbix" {
    command = [ PluginDir + "/check_by_zabbix.sh" ]
    arguments = {
        "-h"  = "$zbx_host$"
        "-H"  = "$zbx_server_url$"
        "-a"  = "$zbx_api_token$"
        "--warn-severity" = "$zbx_warn_severity$"
        "--crit-severity" = "$zbx_crit_severity$"
        "-e"  = "$zbx_exclude$"
        "-i"  = "$zbx_include$"
        "-v"  = {
            set_if = "$zbx_verbose$"
        }
        "--skip-acknowledged" = {
            set_if = "$zbx_skip_acknowledged$"
        }
        "--skip-suppressed" = {
            set_if = "$zbx_skip_suppressed$"
        }
        "--skip-unsupported" = {
            set_if = "$zbx_skip_unsupported$"
        }
    }
    vars.zbx_warn_severity      = "warning"
    vars.zbx_crit_severity      = "average"
    vars.zbx_verbose            = false
    vars.zbx_skip_acknowledged  = false
    vars.zbx_skip_suppressed    = false
    vars.zbx_skip_unsupported   = false
}
```

Create a service definition:

```icinga2
apply Service "Zabbix Triggers" {
    check_command = "check_by_zabbix"
    vars.zbx_host        = host.vars.zabbix_hostname
    vars.zbx_server_url  = "http://zabbix.example.com"
    vars.zbx_api_token   = ZabbixApiToken
    vars.zbx_skip_acknowledged = true

    assign where host.vars.zabbix_hostname != ""
}
```

### Nagios Configuration

Add to `commands.cfg`:

```nagios
define command {
    command_name    check_by_zabbix
    command_line    $USER1$/check_by_zabbix.sh -h $ARG1$ -H $ARG2$ -a $ARG3$
}
```

Add to `services.cfg`:

```nagios
define service {
    use                 generic-service
    host_name           web-prod-01
    service_description Zabbix Triggers
    check_command       check_by_zabbix!web-prod-01!http://zabbix.example.com!your-api-token
}
```

## Security Considerations

- **API Token**: Create a dedicated read-only monitoring user in Zabbix and generate an API token for it. The user only needs read access to hosts and triggers.
- **Credential Storage**: Store API tokens in your monitoring system's secrets store (Icinga2 constants, HashiCorp Vault, etc.) — not in plain-text config files.
- **TLS**: By default TLS certificate verification is disabled for compatibility with self-signed certificates. Enable `--verify-tls` and use a trusted certificate in production environments.
- **Network Access**: The monitoring server requires HTTP/HTTPS access to the Zabbix frontend port. No direct database access is needed.

## Troubleshooting

### Common Issues

**`UNKNOWN - cannot reach Zabbix API at ...`:**
- Verify the `--server-url` and `--api-path` are correct
- Test manually: `curl -sk http://zabbix.example.com/zabbix/api_jsonrpc.php -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":0}'`
- Check that the Zabbix frontend is reachable from the monitoring server

**`UNKNOWN - Zabbix login failed`:**
- Verify username/password, or check that the API token has not expired
- For Zabbix 7.x+, ensure the token was created with sufficient permissions
- Check if the API is enabled: Administration › General › API (Zabbix 5.x/6.x)

**`UNKNOWN - host '...' not found in Zabbix`:**
- Confirm the host name matches the technical name or display name in Zabbix exactly
- Use `-D` (debug) to see the lookup attempts and responses
- Try the substring search by using part of the hostname

**Triggers appear as UNKNOWN (state=1):**
- These are triggers whose expressions cannot be evaluated (item not supported, agent unreachable, or not enough data)
- Use `--skip-unsupported` to suppress them if they are expected for features not in use on this host

**Active problem not detected (trigger is in PROBLEM state in Zabbix but check shows OK):**
- The plugin uses `problem.get` — verify the problem is visible in the Zabbix Problems view
- Problems that are acknowledged and filtered via `--skip-acknowledged` will not be reported
- Use `-D` (debug) to see the raw trigger and problem data returned by the API

### Debug Mode

Enable detailed API trace output:
```bash
./check_by_zabbix.sh -h myhost -H http://zabbix.example.com -a my_token -D 2>&1 | less
```

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-new-check`)
3. Make your changes
4. Test against a real Zabbix instance or a captured API JSON fixture
5. Submit a pull request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Support

For support, please:
1. Review the troubleshooting section above
2. Check existing GitHub issues
3. Open a new issue with your Zabbix version, the full plugin output, and `-D` (debug) output

## Author

**Felix Longardt**
- Email: monitoring@longardt.com
- GitHub: [@ascii42](https://github.com/ascii42)

## Acknowledgments

- The Zabbix team for the comprehensive JSON-RPC API documentation
- The Icinga and Nagios communities for feedback and testing

---

**Note**: This plugin is not officially supported by Zabbix LLC. Use at your own discretion and test thoroughly in your environment before deploying to production monitoring.
