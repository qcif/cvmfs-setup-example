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

### 1. Create a config file

A config file is used to specify the addresses of the four hosts, and
user accounts on them. Those user accounts are expected to have been
configured to use SSH public-keys for authentication. They also are
expected to have _sudo_ privileges without needing to enter a
password.

The config file can be explicitly provided with the `--config` option,
or it searches for a default config file (see `--help` for details).

The config file is a shell script that is sourced by the
_cvmfs-test.sh_ script to obtain the necessary environment variables.

See the _sample-cvmfs-test.conf_ file for details.

### 2. Setup

#### Automatically with OpenStack command

If the OpenStack unified command line client (`openstack`) is
available, source an OpenStack RC file to use it. Create a config file
containing the UUIDs of the four hosts and the Glance image to use
to rebuild them.

Then run:

    ./cvmfs-test.sh reset-all

Depending on the amount of content to add to the repositories, than
can take about an hour to run.

#### Manually without OpenStack command

Manually create the four hosts and then run:

    ./cvmfs-test.sh setup-all

### 3. Test updates

This command changes a file on the Stratum 0, and see how long it
takes for the change to appear on the client.

    ./cvmfs-test.sh test-update
