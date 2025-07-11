#! /usr/bin/perl
#
# Create userdb database
#
# Usage: makeuserdb
#
#
# Copyright 1998 - 2006 Double Precision, Inc.  See COPYING for
# distribution information.

use Fcntl ':flock';

$prefix="/usr";
$exec_prefix="/usr";
$bindir="/usr/bin";

$ENV{'PATH'}="/usr/bin:/usr/bin:/usr/local/bin:/bin";

$dbfile="/etc/authlib/userdb";

$makedat="/usr/lib/courier-authlib/makedatprog";

$name=shift @ARGV;
if ($name eq "-f") {
	$dbfile=shift @ARGV;
	$dbfile=~s/\/$//;
}

$datfile=$dbfile.".dat";
# XXX the lock file here is etc/userdb.lock but the userdb command uses etc/.lock.userdb
$lockfile=$dbfile.".lock";
$shadowfile=$dbfile."shadow.dat";
$tmpdatfile=$dbfile.".tmp";
$tmpshadowfile=$dbfile."shadow.tmp";

$mode=(stat($dbfile))[2];
die "$dbfile: not found.\n" unless defined $mode;

die "$dbfile: MAY NOT HAVE GROUP OR WORLD PERMISSIONS!!\n"
	if ( $mode & 077);

eval {
	die "SYMLINK\n" if -l $dbfile;
};

die "ERROR: Wrong makeuserdb command.\n       ($dbfile is a symbolic link)\n"
	if $@ eq "SYMLINK\n";

eval {
	die "SYMLINK\n" if -l $datfile;
};

die "ERROR: Wrong makeuserdb command.\n       ($datfile is a symbolic link)\n"
	if $@ eq "SYMLINK\n";

eval {
	die "SYMLINK\n" if -l $shadowfile;
};

die "ERROR: Wrong makeuserdb command.\n       ($shadowfile is a symbolic link)\n"
	if $@ eq "SYMLINK\n";

umask (022);
open(LOCK, ">$lockfile") or die "Can't open $lockfile: $!";
flock(LOCK,LOCK_EX) || die "Can't lock $lockfile: $!";

open (DBPIPE, "| ${makedat} - $tmpdatfile $datfile") || die "$!\n";
umask (066);
open (SHADOWPIPE, "| ${makedat} - $tmpshadowfile $shadowfile")
	|| die "$!\n";

eval {

	if ( -d $dbfile )
	{
	my (@dirs);
	my (@files);

		push @dirs, $dbfile;
		while ( $#dirs >= 0 )
		{
			$dir=shift @dirs;
			opendir(DIR, $dir) || die "$!\n";
			while ( defined($filename=readdir(DIR)))
			{
				next if $filename =~ /^\./;
				if ( -d "$dir/$filename" )
				{
					push @dirs, "$dir/$filename";
				}
				else
				{
					push @files, "$dir/$filename";
				}
			}
			closedir(DIR);
		}

		while (defined ($filename=shift @files))
		{
			&do_file( $filename );
		}
	}
	else
	{
		&do_file( $dbfile );
	}

	print DBPIPE ".\n" || die "$!\n";
	print SHADOWPIPE ".\n" || die "$!\n";
} ;

$err=$@;
if ($err)
{
	print "$err";
	exit (1);
}

close(DBPIPE) || die "$!\n";
exit (1) if $?;
close(SHADOWPIPE) || die "$!\n";
exit (1) if $?;

exit (0);

sub do_file {
my ($filename)=@_;
my ($addr, $fields);
my (@nonshadow, @shadow);

my $location=substr($filename, length("/etc/authlib/userdb"));

	$location =~ s/^\///;
	$location =~ s/\/$//;
	$location .= "/" if $location ne "";

	open (F, $filename) || die "$filename: $!\n";
	while (<F>)
	{
		if ( /^[\n#]/ || ! /^([^\t]*)\t(.*)/ )
		{
			print DBPIPE;
			print SHADOWPIPE;
			next;
		}
		($addr,$fields)=($1,$2);
		undef @nonshadow;
		undef @shadow;

		foreach ( split (/\|/, $fields ) )
		{
			if ( /^[^=]*pw=/ )
			{
				push @shadow, $_;
			}
			else
			{
				push @nonshadow, $_;
			}
		}

		push @nonshadow, "_=$location";
		( print DBPIPE "$addr\t" . join("|", @nonshadow) . "\n"
			|| die "$!\n" ) if $#nonshadow >= 0;
		( print SHADOWPIPE "$addr\t" . join("|", @shadow) . "\n"
			|| die "$!\n" ) if $#shadow >= 0;
	}
	print DBPIPE "\n";
	print SHADOWPIPE "\n";
}
