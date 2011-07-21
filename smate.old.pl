#!/usr/bin/perl -w

use strict;

use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
use File::Find;
use File::Path qw(rmtree);
use File::Spec;
use Cwd;
use POSIX qw(WNOHANG SIGCHLD);
use IO::KQueue;

our %kids;

$SIG{INT} = $SIG{TERM} = \&HUNTSMAN;

our $tempdir = tempdir("smate-dir-XXXXXXXX", TMPDIR => 1, CLEANUP => 1);
our $olddir = cwd;

#print "tempdir: $tempdir\n";

chdir($tempdir);

GetOptions(
    'h|help' => \&usage,
);

usage() unless @ARGV;

sub usage {
    print <<EOT;
Usage: $0 [options] [user@]host:/path/to/file

EOT
    exit;
}

main(@ARGV);

sub HUNTSMAN {
    $SIG{CHLD} = 'DEFAULT';
    kill INT => keys %kids;
    chdir($olddir);
    rmtree($tempdir, 0, 0);
    exit 0;
}

sub main {
    my @files = @_;
    
    sanitize(@files);
    
    my $kq = IO::KQueue->new();
    
    foreach my $item (@files) {
        my $dir = tempdir("smate-subdir-XXXXXXXX");
        chdir($dir);
        system("rsync", "-e", "ssh", "-ar", $item, ".");
        my $item_dir = $item;
        $item_dir =~ s/\/[^\/]*$//;
        find(sub { edit_file($item_dir, $kq) }, '.');
    }
    
    while (1) {
        my @events = $kq->kevent();

        foreach my $kevent (@events) {
            my $sub = $kevent->[KQ_UDATA];
            $sub->($kevent) if ref($sub) eq 'CODE';
        }
    }
}

sub edit_file {
    my ($item_dir, $kq) = @_;
    
    return unless -f $File::Find::name;
    
    my $full_path = File::Spec->rel2abs($File::Find::name);
    my $pid = fork();
    if ($pid) {
        open(my $fh, $full_path) || die "open($_) failed: $!";
        my $name = $_;
        $kids{$pid} = [$item_dir, $name, $full_path, $fh];
        $kq->EV_SET(fileno($fh), EVFILT_VNODE,
            EV_ADD | EV_CLEAR,
            NOTE_WRITE,
            0,
            sub { save_file($item_dir, $name, $full_path) });
        $kq->EV_SET(SIGCHLD, EVFILT_SIGNAL, EV_ADD, 0, 0, \&sig_chld);
    }
    else {
        $SIG{HUP} = $SIG{CHLD} = $SIG{INT} = $SIG{TERM} = 'DEFAULT';
        $SIG{PIPE} = 'IGNORE';
        print "Editing file: $full_path\n";
        exec("mate", "-w", $full_path);
    }
}

sub sig_chld {
    my $reaped = 0;
    while ( (my $child = waitpid(-1,WNOHANG)) > 0) {
        last unless $child > 0;

        if (!defined $kids{$child}) {
            next;
        }

        $reaped++;
        my $info = delete $kids{$child};
        
        save_file($info->[0], $info->[1], $info->[2]);
    }
    
    if ($reaped && !%kids) {
        exit 0;
    }
}

sub save_file {
    my ($remote, $rpath, $local) = @_;
    
    $|++;
    print "Re-uploading file: $remote/$rpath...";
    system("rsync", "-e", "ssh", "-ar", $local, "$remote/$rpath");
    print "Done\n";
}

sub sanitize {
    my @files = @_;
    
    foreach my $file (@files) {
        if ($file !~ /^(?:\w+\@)?[\w\.]+:.+$/) {
            die "Invalid filename: $file";
        }
    }
}