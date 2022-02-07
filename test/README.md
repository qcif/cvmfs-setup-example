CernVM-FS testing
=================

This directory contains scripts to simplify testing of the four
CernVM-FS hosts.

A single command can rebuilding everything from scratch. That is,

- rebuild the virtual machines from a Glance image;
- configure the virtual machines with mounted volume storage;
- copying the setup scripts to the hosts;
- running the scripts to set up the hosts and create the repositories;
- copying the public keys from the Stratum 0 host to
  the other hosts that needs them.

Most virtual machines have a small boot disk, so volume storage is
required to support repositories with any serious amount of data.  The
scripts also automate the configuration of the volume storage and puts
the CernVM-FS files on it. **This aspect needs to be
documented. Currently, they have many hard-coded conventions are followed.**

The script has been designed for use with virtual machine instances
running in OpenStack. But if the rebuild step is not used, it should
work with any type of physical or virtual machines.

Contents
--------

- _cvmfs-test.sh_ - the setup script. It invokes these helper scripts:
    - _vm-rebuild.sh_ - to rebuild the virtual machines
    - _vm-volume-setup.sh_ - to setup volume storge on the hosts
    - _repo-populate.sh_ - to populate the initial contents of the repositories.
    - _monitor-file.sh_ - used to detect when a file changes
- _sample-cvmfs-test.conf_ - example configuration file for the setup script.

Requirements
------------

- OpenStack command line client
- Four virtual machine instances
- Volume storage for each of the VM instances (except the client host)
  to support larger repositories.
- Content for the populating the repositories. (Optional)

Procedure
---------

### 1. Preparation

1. Launch four virtual machines.
2. Create volume storage for all of them (except for the client host).
3. Attached the volume storage to their virtual machines.

Install the OpenStack unified command line client (`openstack`) on a
the machine that will be running the _cvmfs-test.sh_ script.

Obtain the OpenStack RC file for the OpenStack client.

### 1. Create a config file

Use the _sample-cvmfs-test.conf_ file as a guide to create a
config file for the script.

The config file is a shell script that is sourced by the
_cvmfs-test.sh_ script to obtain the necessary environment variables.

The config file identifies:

- the Glance image used to rebuild the virtual machines (e.g. CentOS Stream 8);
- the four virtual machine instances (identified by their UUIDs);
- the IP addresses of the four virtual machine instances;
- the user account with sudo access on the rebuilt virtual machines
  (e.g. "ec2-user" when using RHEL-based images);
- the user account on the Stratum 0 host that can publish to the
  CernVM-FS repositories that will be created;
- some size limits used when setting up the hosts;
- the names of the CernVM-FS repositories to create; and
- optionally content to populate the repositories with.

The config file can be specified with the `--config` option, or it
tries to use "cvmfs-test.conf" in the current directory.  If that is
not found, it tries the user's home directory for a file called
".cvmfs-test.conf" or ".config/cvmfs-test.conf".

To check the contents of the config file, run:

```sh
./cvmfs-test.sh show-config
```

### 2. Setup

#### Automatically with OpenStack command

If the OpenStack unified command line client (`openstack`) is
available, source an OpenStack RC file to use it. Create a config file
containing the UUIDs of the four hosts and the Glance image to use
to rebuild them.

Then run:

```sh
./cvmfs-test.sh reset-all
```

Depending on the amount of content to add to the repositories, this
can take about an hour to run.

#### Manually without OpenStack command

Manually create the four hosts and then run:

```sh
./cvmfs-test.sh setup-all
```

This performs all the steps, except for rebuilding the virtual
machines with a Glance image.

This alternative can be used if non-OpenStack virtual machines are
being used for testing. In which case, the virtual machines need to be
restored/rebuilt/re-imaged before running the script.

### 3. List repositories

After setup, the available repositories can be lised by running:

```sh
./cvmfs-test.sh list-repos
```

On the Stratum 1 Web server at `http://<stratum-1-host>/info/` the
repositories are also listed and their public keys can be downloaded.

### 4. Test updates

This command changes a file on the Stratum 0, and then monitors for
that change to appear on the client.

```sh
./cvmfs-test.sh test-update
```

How long a change takes to propagate to clients depends on several
factors, including the update frequency configured into the Stratum 1
hosts.

## More information

For a brief summary of the options:

```sh
./cvmfs-test.sh --help
```
