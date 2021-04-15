# CernVM-FS setup for demonstration CVMFS repositories

Scripts for setting up an example CernVM-FS system.  These scripts can
be used to deploy the following servers:

- CernVM-FS Stratum 0
- CernVM-FS Stratum 1 replicas
- CernVM-FS caching proxies
- CernVM-FS clients

The _CernVM-File System_ is a distributed file system. Files are
stored efficiently using a content addressable file system. Files are
transferred efficiently using a series of distributed caches, which
also provide redundancy.

- CernVM-FS repositories are deployed as a single Stratum 0 central
  server, which is the only place where files in the repository are
  modified.

- The Stratum 1 replicas are full copies of the Stratum 1 repository.

- The caching proxies may contain a cached copy of the files which
  have been accessed through it.

- The clients make the repositories available to its users, mounted
  under the _/cvmfs_ directory using _autofs_. The clients access the
  repositories as a read-only file system.

**These scripts are not intended for use in a production system.**

## Example usage

This example shows the use of these scripts to create and use a
CernVM-FS repository called _data.example.org_.

It is assumed there are four hosts are:

- 10.0.0.1 for the Stratum 0
- 10.1.1.1 for a Stratum 1
- 10.2.2.2 for a caching proxy
- 10.3.3.3 for a client (with other clients being in the range 10.3.3.0/24)

First, copy the four scripts to their respective hosts.

Note: all the scripts support the `--help` option, to print out a
brief description of the available options.

The `--verbose` option is used so the scripts will print out what they
are doing. Otherwise, no output is produced unless an error
occurs. The scripts take several minutes to run, so it can be
reassuring to see some output as it runs.

### Stratum 0

Create the Stratum 0 central server by running:

```sh
[stratum-0]$ sudo ./cvmfs-stratum-0-setup.sh -v data.example.org
```

Keys for the repository will be generated.  Copy the public key for
the created repository (from "/etc/cvmfs/keys/data.example.org.pub")
to the Stratum 1 host(s) and to the client host(s).

The Stratum 1 host(s) must be able to connect to port 80 on the
Stratum 0 host.

### Stratum 1

Create a Stratum 1 replica by running:

```sh
[stratum-1]$ sudo ./cvmfs-stratum-1-setup.sh -v \
  --stratum-0 10.0.0.1 \
  --servername 10.1.1.1 \
  --refresh 2 \
  data.example.org.pub
```

The optional `--servername` is used to set the _ServerName_ in the
Apache Web Server configuration.

The refresh is used as the step value in the minutes field for the
cron job that refreshes the replica from the Stratum 0 repository.  It
is set to 2 minutes here, so changes are propagated more quickly.

The file name of the public key should be the _fully qualified
repository name_ followed by a ".pub" extension. The script uses the
basename of the file name without the ".pub" extension as the _fully
qualified repository name_. If the file name is different, the
argument must be the _fully qualified repository name_ followed by a
colon and the file name (e.g. "data.example.org:pubkey.pem").

The proxy host(s) must be able to connect to ports 80 and 8000 on the
Stratum 1 host(s).

### Proxy

Create a proxy by running:

```sh
[proxy]$ sudo ./cvmfs-proxy-setup.sh -v --stratum-1 10.1.1.1 10.3.3.0/24
```

The client host(s) must be able to connect to port 3128 on the proxy
host(s). That is the conventional port used for CernVM-FS caching
proxies, but it can be changed via a command line option on the
script.

### Client

Create a client by running:

```sh
[client]$ sudo ./cvmfs-client-setup.sh -v \
  --stratum-1 10.1.1.1 --proxy 10.2.2.2 --no-geo-api data.example.org.pub
```

The `--no-geo-api` option is required, because the Stratum 1 server
was not configured with a _Geo API license key_.  To use the Geo API,
a license key needs to be obtained from
[MaxMind](https://www.maxmind.com/) and used to configure the Stratum
1 replica.

Like for the Stratum 1 setup script, the file name of the public key
should be the fully qualified repository name followed by a ".pub"
extension; or it must contain the _fully qualified repository name_
followed by the file name separated by a colon.

#### Access the repository from the client

Initially, there are no mount points under the _/cvmfs_ directory,
since the repositories are automatically mounted when they are
accessed (and are automatically unmounted when not used).

```sh
[client]$ ls /cvmfs
[client]$ ls /cvmfs/data.example.org
new_repository
[client]$ ls /cvmfs
data.example.org
```

#### Make changes to the repository

Add or modify files in the repository by starting a transaction,
making the changes and then publishing the changes.

```sh
[stratum-0]$ cvmfs_server transaction data.example.org
[stratum-0]$ echo "Hello world!" > /cvmfs/data.example.org/README.txt
[stratum-0]$ cvmfs_server publish data.example.org
```

If the above commands are run as the repository user, root privileges
are not required.

To close a transaction without publishing (i.e. discarding any
changes), run `cvmfs_server abort`.

#### See the changes appear on the client

Wait for about 3 minutes and then check for the changes to appear on
the client. The cron job on the Stratum 1 host (to update/snapshot the
repository) was set to run every 2 minutes, and a little more time is
needed for it and the proxy and client caches to update.

```sh
[client]$ ls /cvmfs/data.example.org
new_repository  README.txt
[client]$ cvmfs_config stat -v
```

The _monitor-file.sh_ script can be used to detect when a file changes in
the client, instead of manually waiting for it to change.

## Requirements

### Supported distributions

The scripts only work on Linux, since they use the _yum_ or _apt-get_
package managers to install the CVMFS software.

All of the setup scripts have been tested on:

- CentOS 7
- CentOS 8
- CentOS Stream 8

The proxy and client setup scripts have also been tested on:

- Ubuntu 20.04

### Summary of firewall and routing requirements

The Stratum 0 host must allow access to its port 80 from the Stratum 1 hosts.

The Stratum 1 hosts must allow access to its ports 80 and 8000
from the proxy hosts.

The proxy hosts must allow access to its port 3128 from the clients.

## Bonus features

### Very verbose mode

The output from the _cvmfs_server_ command will be printed out if the
scripts are run in very verbose mode: by specifying the `-v` option
twice. It is only useful for the Stratum 0 and Stratum 1 scripts.

### Extended help

Extra information is displayed when `-v` is used along with `-h`. That
information is not related to the script, but are reminder of related
CernVM-FS commands.

## Limitations

- Installs the Squid from the distribution, which is old and
  deprecated.  A production deployment should use a newer version of
  Squid.

- Only one organisation is supported. But multiple repositories under
  that organisation are possible.


## More information

Run the scripts with the `--help` option.

## Acknowledgements

This work is supported by the Australian BioCommons which is enabled
by NCRIS via Bioplatforms Australia funding.

## See also

- [CVMFS documentation](https://cvmfs.readthedocs.io/en/stable/)
