#!/usr/bin/env perl
#
# Copyright (c) 2005-2006 The Trustees of Indiana University.
#                         All rights reserved.
# Copyright (c) 2006-2008 Cisco Systems, Inc.  All rights reserved.
# Copyright (c) 2007      Sun Microsystems, Inc.  All rights reserved.
# $COPYRIGHT$
# 
# Additional copyrights may follow
# 
# $HEADER$
#

package MTT::Values::Functions::SSH;

use strict;
use MTT::Values::Functions;
use MTT::DoCommand;
use MTT::Messages;
use MTT::FindProgram;
use MTT::Lock;
use File::Temp qw(tempfile);

#--------------------------------------------------------------------------

# If ~/.ssh/known_hosts is stale, refresh it. Otherwise do
# nothing.
#
# EAM: This funclet is not scalable. it needs to be coded
# using threads or fork() so that it can run efficiently
# over a large number of hosts
#
# CAUTION! USE OF THIS FUNCLET IS ONLY ADVISABLE IN UNSTABLE
# AND SECURE ENVIRONMENTS (E.G., LAB NETWORKS).
sub refresh_known_hosts_file {

    my $funclet = '&' . FuncName((caller(0))[3]);
    Debug("$funclet: got @_\n");

    my $env_hosts = &MTT::Values::Functions::env_hosts(1);

    my @hosts = split(/,/, $env_hosts);
    my @stale_host_keys;

    foreach my $host (@hosts) {
        my $x = MTT::DoCommand::Cmd(1, "ssh $host");

        if ($x->{exit_status} != 0) {
            push(@stale_host_keys, $host);
        }
    }

    my $sshfile = "$ENV{HOME}/.ssh/known_hosts";

    if (@stale_host_keys) {
        Verbose("Host key verification failed for the following hosts:\n\t" .
                join("\n\t", @stale_host_keys) . "\n");

        foreach my $host (@stale_host_keys) {
            if (! _strip_line_from_ssh_file($sshfile, $host)) {
                Warning("Could not edit $sshfile.\n");
                return undef;
            }
        }

    } else {
        return 1;
    }

    # Create a simple expect script to update the SSH
    # known_hosts file
    my ($fh, $filename) = tempfile(DIR => MTT::DoCommand::cwd(), 
                                   SUFFIX => "-update-ssh-known-hosts-file");

    my $expect_path = FindProgram(qw(expect));
    if (! $expect_path) {
        Warning("$funclet() can not continue wihtout 'expect'.\n");
        return undef;
    }

    my $scriptlet = "#!/usr/bin/env expect
#
# This script was automatically generated by $funclet().
# Changes you make to it will be lost!
#
";
    $scriptlet .= '
set host [ lindex $argv 0 ]
puts "\nAdding ssh $host hostkey"
spawn ssh $host
expect "(yes/no)? " { send "yes\n\r" } 
sleep 2
puts "\nHost key for $host added."
';

    print $fh $scriptlet;
    close($fh);
    chmod(0700, $filename);

    foreach my $host (@stale_host_keys) {
        my $x = MTT::DoCommand::Cmd(1, "$filename $host");

        if ($x->{exit_status} != 0) {
            Warning("$filename failed to execute.");
            return undef;
        } else {
            BigWarning("You have instructed MTT to update ",
                       "the entry for '$host' in your $sshfile!",
                       "(You are using $funclet() somewhere " ,
                       "in your INI file.)",
                       "This is advisable only in unstable ",
                       "and secure environments (e.g., lab networks).");
        }
    }

    # Remove "expect" script
    unlink($filename);
}

# Remove line from ~/.ssh/known_hosts that matches @_
sub _strip_line_from_ssh_file {

    my ($sshfile, $pattern) = @_;

    # The rest of this section must be serialized because only one
    # process can modify the $HOME/.ssh/known_hosts file at a time.
    # Blah!
    MTT::Lock::Lock($ENV{HOME} . "/.ssh/known_hosts");

    # Read in the original $HOME/.ssh/known_hosts file
    my $known_hosts_file;
    mkdir("$ENV{HOME}/.ssh")
        if (! -d "$ENV{HOME}/.ssh");
    if (-r $sshfile) {
        open(FILE, $sshfile);
        while (<FILE>) {
            $known_hosts_file .= $_;
        }
        close FILE;
    } else {
        $known_hosts_file = "";
    }

    # Write out a new $HOME/.ssh/known_hosts file with the
    # right proxy info
    my $out = $known_hosts_file;
    $out =~ s/^\b$pattern\b.*//m;

    open(FILE, ">$sshfile");
    my $ok = print FILE $out;
    close(FILE);

    # Reset the known_hosts file to whatever it used to be (if it used to be!)
    MTT::Lock::Unlock($ENV{HOME} . "/.ssh/known_hosts");

    if (!$ok) {
        return undef;
    } else {
        return 1;
    }
}

1;
