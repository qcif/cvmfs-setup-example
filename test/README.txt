CernVM-FS testing
=================

This directory contains scripts to simplify testing all four hosts.

Requirements
------------

- OpenStack command line client
- Four virtual machine instances
- Volume storage for each of the VM instances (except the client host)
  to support larger repositories.
- Content for the populating the repositories. (Optional)

Procedure
---------

1. Create a config file for your environment. See sample-cvmfs-test.conf.

2. Rebuild the operating system on the VM instances and install the hosts:

    ./cvmfs-test.sh reset-all

   This takes about an hour to run.

3. Change a file on the Stratum 0 and see how long it takes for the change
   to appear on the client.

    ./cvmfs-test.sh test-update

### Config file

A config file can be used to specify the addresses of the four hosts,
and user accounts on them. Those user accounts are expected to have
been configured to use SSH public-keys for authentication. They also
are expected to have _sudo_ privileges without needing to enter a
password.

See the _sample-cvmfs-test.conf_ file for details.

The config file can be explicitly provided with the `--config` option,
or it searches for a default config file (see `--help` for details).

The config file is a shell script that is sourced by the
_cvmfs-test.sh_ script to obtain the necessary environment
variables.
