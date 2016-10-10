# Check_Foreman

### A [Nagios](https://www.nagios.org/) / [Icinga](https://www.icinga.org/) check plugin for [The Foreman](https://theforeman.org/)

A simple plugin written in ruby, since I could not find one. Checks are done using Foreman REST API v2.

## Supported checks

- Foreman Dashboard, finds number of *bad_hosts*
- Generic Host search query, eg. out of sync etc.
- Search host facts

You can use the same search queries as used in foreman UI. For long and complicated queries Base64 encoding is supported.

### Example
```bash
./check_foreman.rb --endpoint=https://foreman.example.com/api/v2 --user=icinga --password=Secret
```
![Icinga2:Foreman Dashboard check with graphite graphs](img/icinga2.png?raw=true "Foreman Dashboard check with graphite graphs")


## Installation
- **Prerequisite 1:** [Ruby >= 1.8](https://www.ruby-lang.org/) and [rubygem-bundler](https://rubygems.org/gems/bundler/) 
need to be installed on the machine running the checks
- **Prerequisite 2:** Since checks are done using HTTPS, the RootCA for your foreman instance needs to be trusted

1. Clone this repository to the machine doing the service checks. Usually this will be a nagios collector or
icinga master
2. Change into the directory and run `bunlde install`.
3. Check the command by running `./check_foreman.rb -h` and the above example. Replace endpoint, user and password 
with valid values.

## Usage
Command line usage is basically like any other nagios plugin.

The main argument is `--command`, defining witch check is run (`dashboard` is the default).

- `dashboard`: Check foreman dashboard
- `search`: search hosts for search query supplied by `--argument`
- `fact`: search fact values for search query supplied by `--argument`

#### Hints
- Test search queries in foreman and use the same query
- If queries are complicated and hard to escape supply base64 encoded arguments, `--base64`. Use `--convert64` for convenience


```
-u, --user                       Foreman API user
-p, --password                   Foreman API password
-H, --endpoint                   Foreman API endpoint URL
-v, --[no-]verbose               Enable verbose output for debugging
-a, --argument                   Check command argument
-B, --[no-]base64                Assume base64 encoded argument
-C, --command dashboard          Check command. One of "dashboard", "search", "fact". "search" will search hosts for argument, fact will search "facts"
-w, --warning 1                  Warning value
-c, --critical 5                 Critical value
-P, --[no-]silent                Suppress performance data output
-o, --[no-]encode64              Helper: Encode value from STDIN to base64
-h, --help                       Show this message
-V, --version                    Print version
```

## Configuring Icinga2

I use Icinga2, hence there is only my example configuration. PR's for nagios/icinga1 welcome!

Note, I added `vars.graphite_keys`. These only make sense if you use the 
[icingaweb2-graphite](https://github.com/findmypast/icingaweb2-module-graphite)


### Define constants, eg. `constants.conf`
```c#
const CustomPlugins = "/path/to/plugin-dir"
const ForemanApi = "https://foreman.example.com/api/v2"
const ForemanApiUser = "icinga"
const ForemanApiPass = "secret"
```

### Add foreman check command, eg. `conf.d/commands.conf`
```c#
object CheckCommand "foreman" {
  import "plugin-check-command"
  import "ipv4-or-ipv6"
  command = [ CustomPlugins + "/check_foreman.rb" ]
  timeout = 1m
  arguments = {
    "-w" = {
      value = "$foreman_warning$"
      description = "Warning value"
    }
    "-c" = {
      value = "$foreman_critical$"
      description = "Critical value"
    }
    "-H" = {
      value = "$foreman_endpoint$"
      description = "Foreman API endpoint URL"
    }
    "-C" = {
      value = "$foreman_command$"
      description = "Check command. One of 'dashboard', 'search', 'fact'"
    }
    "-a" = {
      value = "$foreman_argument$"
      description = "Check command argument"
    }
    "-u" = {
      value = "$foreman_user$"
      description = "Foreman API user"
    }
    "-p" = {
      value = "$foreman_password$"
      description = "Foreman API password"
    }
    "-B" = {
      description = "Assume base64 encoded argument"
      set_if = "$foreman_arg_base64$"
    }
    "-v" = {
      description = "Verbose output"
      set_if = "$foreman_verbose$"
    }
  }
  vars.foreman_verbose = false
  vars.foreman_arg_base64 = false
}
```

### Add a service template, eg. `conf.d/templates.conf`

```c#
template Service "foreman_api" {
  vars.foreman_user = ForemanApiUser
  vars.foreman_password = ForemanApiPass
  vars.foreman_endpoint = ForemanApi
  
  host_name = "foreman.example.com"
  check_command = "foreman"
}
```

### Example checks, eg. `conf.d/foreman_services.conf`

#### Check foreman dashboard. Throw critical if >= 5 hosts have errors (eg applying manifests)
```c#
object Service "Foreman Dashboard" {
  import "generic-service"
  import "foreman_api"

  vars.foreman_warning = 1
  vars.foreman_critical = 5
  vars.foreman_command = "dashboard"
  check_interval = 5m

  vars.graphite_keys = ["{total_hosts,bad_hosts,ok_hosts}","{active_hosts,active_hosts_ok,out_of_sync_hosts}"]
}
```

#### Search `my_hostgroup` host group manifests. They should never be out of sync

[Decoded](https://www.base64decode.org/): `environment = production and hostgroup_fullname ~ my_hostgroup and 
(last_report < "1 hour ago" or (status.failed > 0 or status.failed_restarts > 0 or status.skipped > 0))"`

Since this query is rather awkward to supply as argument, it is supplied base64 encoded


```c#
object Service "Foreman Puppet Manifests my_hostgroup" {
  import "generic-service"
  import "foreman_api"

  vars.foreman_critical = 1
  vars.foreman_command = "search"
  vars.foreman_arg_base64 = true
  vars.foreman_argument = "ZW52aXJvbm1lbnQgPSBwcm9kdWN0aW9uIGFuZCBob3N0Z3JvdXBfZnVsbG5hbWUgfiBteV9ob3N0Z3JvdXAgYW5kIChsYXN0X3JlcG9ydCA8ICIxIGhvdXIgYWdvIiBvciAoc3RhdHVzLmZhaWxlZCA+IDAgb3Igc3RhdHVzLmZhaWxlZF9yZXN0YXJ0cyA+IDAgb3Igc3RhdHVzLnNraXBwZWQgPiAwKSki"
 
  check_interval = 5m
}
```

#### Search host fact values. In this case, the custom fact `rootfsusage` is checked. 
**Note:** This currently only works with number style fact values witch are converted to float.

```c#
object Service "Disk Facts" {
  import "generic-service"
  import "foreman_api"
 
  vars.foreman_warning = 70 // warn < 30% free space
  vars.foreman_critical = 90 // critical if < 10% free space
  vars.foreman_command = "fact"
  vars.foreman_argument = "name = rootfsusage and host.hostgroup = my_hostgroup"
  check_interval = 30m // only update once per puppet run

  vars.graphite_keys = ["{ok_count,warning_count,critical_count}"]
}
```

