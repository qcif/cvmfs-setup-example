# Changelog

## 1.8.0

- Created troubleshooting document.
- Added experimental feature to install a specific version of CernVM-FS.
- Added more tested distributions.
- Disabling default domain configurations.
- Fixed bug with warning message for already installed package in Ubuntu.

## 1.7.0

- Changed multiple proxies to be put in one group instead of multiple groups.

## 1.6.0

- Updated support for Rocky Linux 9.
- Documented use with repositories from multiple organisations.

## 1.5.0

- Changed test/vm-volume-setup.sh to use bind mounts instead of symlinks.

## 1.4.0

- Fixed bug with "already installed" for Ubuntu.
- Tested with Rocky Linux 8.5.

## 1.3.0

- Refactored code.
- Added support for setting the CVMFS_FILE_MBYTE_LIMIT on Stratum 0.
- Added support for setting the disk cache size on the caching proxy.
- Created test utilities.
- Added maximum object size option for cvmfs-proxy-setup.sh.
- Added setup-all command to not perform rebuild of VM instances.
- Changed default for the client setup script to not use Geo API.

## 1.2.0

- Added publisher account for Stratum 0.

## 1.1.0

- Added support for Stratum 0 and Stratum 1 on Ubuntu hosts.
- Created setup-example.sh script to simplify testing.
- Added setup-example.sh and "setup-all" command to automate testing.

## 1.0.0

- Initial release.
