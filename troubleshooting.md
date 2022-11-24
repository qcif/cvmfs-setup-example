Troubleshooting CernVM-FS
=========================

## Table of Contents

1. [Introduction](#1)
    - 1.1. [Process](#1.1)
2. [Stratum 0 host](#2)
    - 2.1. [CernVM-FS installed](#2.1)
    - 2.2. [Published files](#2.2)
    - 2.3. [Apache HTTP Server](#2.3)
3. [Stratum 1 host](#3)
    - 3.1. [Accessing the Stratum 0](#3.1)
    - 3.2. [CernVM-FS installed](#3.2)
    - 3.3. [Apache HTTP Server](#3.3)
4. [Proxy host](#4)
    - 4.1. [Accessing the Stratum 1](#4.1)
    - 4.2. [No CernVM-FS](#4.2)
    - 4.3. [Squid proxy](#4.3)
5. [Client host](#5)
    - 5.1. [Accessing the proxy cache](#5.1)
    - 5.2. [CernVM-FS client settings](#5.2)

<a class="markdown-toc-generated" id="1"></a>
## 1. Introduction

This document describes some troubleshooting steps that can be taken,
If an installation of CernVM-FS does not work.

<a class="markdown-toc-generated" id="1.1"></a>
### 1.1. Process

This document starts at the Stratum 0 host and ending up with the
client host. This is a methodical approach approach, which checks the
foundations are working before checking the components that depend on
the fountation.

Sometimes it is better to start troubleshooting at the bottom and work
back up. The best approach would depend on the source of the problem,
but if you knew that you wouldn't need to troubleshoot!

Try the last step in this document first! And then decide what is the
best approach.

<a class="markdown-toc-generated" id="2"></a>
## 2. Stratum 0 host

The Stratum 0 host contains the master copy of the repositories. It
runs an _Apache HTTP Server_ to make the published files available to
the Stratum 1 hosts.

<a class="markdown-toc-generated" id="2.1"></a>
### 2.1. CernVM-FS installed

There should be directories under _/cvmfs_ corresponding to each
repository.

```shell
S0$ ls /cvmfs
data.example.org  tools.example.org
```

Note: unlike on the client hosts, they are not _autofs_ mounts. In
fact, autofs does _not_ need to be running on the Stratum 0 host.

<a class="markdown-toc-generated" id="2.2"></a>
### 2.2. Published files

There should be a _/srv/cvmfs_ directory, and under it an _info_
directory and a directory corresponding to each repository.

```shell
S0$ ls /srv/cvmfs
data.example.org  info  tools.example.org
```

Each repository has a _data_ subdirectory and some hidden files
(starting with a full stop). For example,

```shell
S0$ ls -aF1 /srv/cvmfs/data.example.org
./
../
.cvmfs_master_replica
.cvmfspublished
.cvmfsreflog
.cvmfswhitelist
data/
```

Only one of those files contains text, the others are binary data
files. Examine the contents of that text file:

```shell
S0$ cat /srv/cvmfs/data.example.org/.cvmfs_master_replica 
This file marks the repository as replicatable to stratum 1 servers
```

The _data_ subdirectories contains subdirectories for the CernVM-FS
processed content. It contains 256 subdirectories, with two
hexadecimal digit names (e.g. "00", "01", through to "ff") plus a
_txn_ subdirectory.

<a class="markdown-toc-generated" id="2.3"></a>
### 2.3. Apache HTTP Server

Each of those directories under _/srv/cvmfs_ should have a
corresponding configuration file for the _Apache HTTP Server_ to serve
their contents over HTTP.
   
```shell
S0$ ls -1 /etc/httpd/conf.d/cvmfs.*.conf
/etc/httpd/conf.d/cvmfs.data.example.org.conf
/etc/httpd/conf.d/cvmfs.tools.example.org.conf
/etc/httpd/conf.d/cvmfs.info.conf
```

If you examine those configuration files, they contain statements to
serve up the directory (e.g. _/srv/cvmfs/data.example.org_) on a URL
path (e.g. _/cvmfs/data.example.org_).

Check the _Apache HTTP Server_ is running:

```shell
S0$ systemctl status httpd.service
```

Check if it is serving up the expected files from a repository:

```shell
S0$ curl -v http://localhost/cvmfs/data.example.org/.cvmfs_master_replica
```

This should return the same contents as the corresponding text file.

Try the same request, but with the actual hostname or IP address:


```shell
S0$ curl -v http://stratum0.example.com/cvmfs/data.example.org/.cvmfs_master_replica
```

<a class="markdown-toc-generated" id="3"></a>
## 3. Stratum 1 host

<a class="markdown-toc-generated" id="3.1"></a>
### 3.1. Accessing the Stratum 0

The Stratum 1 host must be able to access the HTTP server (port 80) on
the Stratum 0 host.

Check if the Stratum 1 host can access the HTTP server on the Stratum
0 host. This is the same command as above, but run on the Stratum 1:

```shell
S1$ curl -v http://stratum0.example.com/cvmfs/data.example.org/.cvmfs_master_replica
```

This should produce the same output that was obtained when running _curl_
on the Stratum 0 host.

If it fails, check why the Stratum 1 cannot connect to the HTTP server
on the Stratum 0. For example, see if it can _ping_ the Stratum 0 host
and if there are any firewall rules blocking access.

<a class="markdown-toc-generated" id="3.2"></a>
### 3.2. CernVM-FS installed

Unlike the Stratum 0, the Stratum 1 host should have an empty _/cvmfs_ directory.

```shell
S1$ ls /cvmfs
```

It has the same _/srv/cvmfs_ directory:

```shell
S1$ ls /srv/cvmfs
data.example.org  info  tools.example.org
```

But the contents of each repository subdirectory is slightly different.

```shell
S1$ ls -aF1 /srv/cvmfs/data.example.org
./
../
.cvmfs_last_snapshot
.cvmfspublished
.cvmfsreflog
.cvmfs_status.json
.cvmfswhitelist
data/
```

Instead of a _.cvmfs_master_replica_ file, there are the
_.cvmfs_last_snapshot_ and _.cvmfs_status.json_ files.

Examine the contents of one of them:

```shell
S1$ cat /srv/cvmfs/data.example.org/.cvmfs_status.json
{
  "last_snapshot": "Thu Nov 24 04:35:02 UTC 2022"
}
```

<a class="markdown-toc-generated" id="3.3"></a>
### 3.3. Apache HTTP Server

Each of those directories under _/srv/cvmfs_ should have a
corresponding configuration file for the _Apache HTTP Server_ to serve
their contents over HTTP.
   
```shell
S1$ ls -1 /etc/httpd/conf.d/cvmfs.*.conf
/etc/httpd/conf.d/cvmfs.data.example.org.conf
/etc/httpd/conf.d/cvmfs.tools.example.org.conf
/etc/httpd/conf.d/cvmfs.info.conf
/etc/httpd/conf.d/cvmfs.+webapi.conf
```

Check the _Apache HTTP Server_ is running:

```shell
S1$ systemctl status httpd.service
```

Check if it is serving up the expected files from a repository:

```shell
S1$ curl -v http://localhost/cvmfs/data.example.org/.cvmfs_status.json
```

This should return the same contents as the corresponding JSON file.

Try the same request, but with the actual hostname or IP address:

```shell
S1$ curl -v http://stratum1.example.com/cvmfs/data.example.org/.cvmfs_master_replica
```

<a class="markdown-toc-generated" id="4"></a>
## 4. Proxy host

<a class="markdown-toc-generated" id="4.1"></a>
### 4.1. Accessing the Stratum 1

The proxy host must be able to access the HTTP server (port 80) on the
Stratum 1 host.

Check if the Caching Proxy host can access the HTTP sserver on the
Stratum 1 host. This is the same command as above, but run on the
proxy host:

```shell
PROXY$ curl -v http://stratum1.example.com/cvmfs/data.example.org/.cvmfs_master_replica
```

<a class="markdown-toc-generated" id="4.2"></a>
### 4.2. No CernVM-FS

The proxy host does not have CernVM-FS installed. So it should not
have a _/cvmfs_ directory, nor a _/srv/cvmfs_ directory.

<a class="markdown-toc-generated" id="4.3"></a>
### 4.3. Squid proxy

The proxy host should be running the Squid proxy:

```shell
PROXY$ systemctl status squid.service
```
   
And the above resource should be obtainable via the Squid proxy:

```shell
PROXY$ curl -x localhost:3128 \
       http://stratum1.example.com/cvmfs/data.example.org/.cvmfs_status.json
```

Try the same request, but with the actual hostname or IP address:

```shell
PROXY$ curl -x proxy.example.com:3128 \
       http://stratum1.example.com/cvmfs/data.example.org/.cvmfs_status.json
```

<a class="markdown-toc-generated" id="5"></a>
## 5. Client host

<a class="markdown-toc-generated" id="5.1"></a>
### 5.1. Accessing the proxy cache

The client host must be able to connect to the Squid proxy (running on
port 3128 by default) on the proxy host.

Check if the client host can access the Stratum 1 via the Squid proxy.
This is the same command as above, but run on the client host:

```shell
CLIENT$ curl -x proxy.example.com:3128 \
        http://stratum1.example.com/cvmfs/data.example.org/.cvmfs_status.json
```

If all of the above works, then the "plumbing" appears to be working
correctly. The correct services are running and there is nothing
blocking the network communications.

<a class="markdown-toc-generated" id="5.2"></a>
### 5.2. CernVM-FS client settings

Check if the client configuration is correct and the repository can be accessed:

```shell
CLIENT$ sudo cvmfs_config chksetup
```

```shell
CLIENT$ ls /cvmfs/data.example.org
```
