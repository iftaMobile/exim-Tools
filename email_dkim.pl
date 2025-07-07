#!/usr/bin/perl
#
# DKIM automatisiert erstellen
#
#   (c) 2022 Juergen Weiss <mail@juwei.de>
#       All rights reserved.
#       Last update 17.08.2022

use strict;
use DB_File;
use Net::DNS;
use POSIX qw(strftime);

my $file = '/etc/exim/db/domains.db';
my $date = strftime "%Y%m%d", localtime;

my %h;
dbmopen(%h, $file, 0) || die "$0: dbmopen($file): $!\n";

my @domains = keys %h;
my @update_serial;

foreach my $domain (@domains) {
	$domain =~ s/\0$//;
	if (!-f '/etc/exim/dkim/'.$domain.'.pem') {
			`/usr/bin/sudo -u mail /bin/sh -c "umask 177 && /usr/bin/openssl genrsa -out '/etc/exim/dkim/$domain.pem' 1024 -outform PEM"`;
			`/usr/bin/sudo -u mail /bin/sh -c "umask 133 && /usr/bin/openssl rsa -in '/etc/exim/dkim/$domain.pem' -out '/etc/exim/dkim/$domain.pub' -pubout -outform PEM"`;
	}
	my $soa = `/usr/bin/dig -t NS "$domain" +short \@1.1.1.1`;
	my $txt = `/usr/bin/dig -t TXT "20220817._domainkey.$domain" +short \@ns1.netzland.net`;
	if ($soa =~ 'ns1.netzland.net.' && $txt eq '') {
		my $pubkey = `/bin/cat "/etc/exim/dkim/$domain.pub"`;
		$pubkey =~ s/^-----BEGIN PUBLIC KEY-----\n//;
		$pubkey =~ s/-----END PUBLIC KEY-----$//;
		$pubkey =~ s/\n//g;
		#print($domain, ": ", "20220817._domainkey", " ", "TXT", " ", "\"k=rsa; p=".$pubkey."\"", "\n");
		print "DELETE FROM `records` WHERE `name` = '20220817._domainkey.", $domain, "' AND `type` = 'TXT';\n";
		print "INSERT INTO `records` (domain_id, name, type, content, ttl) SELECT id, '20220817._domainkey.", $domain, "', 'TXT', '\"k=rsa; p=".$pubkey."\"', 3600  FROM domains WHERE name = '", $domain, "';", "\n";
		push @update_serial, $domain;
	}
}

if (@update_serial > 0) {
	print "\n";
	print "UPDATE records SET content = 'ns1.netzland.net hostmaster.netzland.net ", $date,"01 3600 3600 604800 3600' where type = 'SOA' AND content like 'ns1.netzland.net%' AND name IN('", join("','", @update_serial), "');\n";
}
else {
	print "Es gibt nichts zu tun, alle Domains sind angelegt.\n";
}
__END__
