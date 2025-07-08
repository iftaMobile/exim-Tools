#!/usr/bin/perl
#
# Mail konfigurieren
#
#   (c) 2014 Netzland Ltd by Juergen Weiss
#       All rights reserved.
#       Last update 04.07.2014

use strict;
use DBI qw(:sql_types);
use DBD::mysql;
use Digest::MD5 qw(md5_hex);
use Crypt::PasswdMD5;
use IDNA::Punycode;
use Encode qw(decode encode);


# Verbindung zur Datenbank herstellen
my $dbh = DBI->connect("dbi:mysql:database=webhosting:host=80.153.174.96:port=43306", "webhosting", "webhosting", {
                          PrintError  => 0,
                          RaiseError  => 0
} ) or &sqlerr(__LINE__);

my %users;
my %accounts;

# load users
my $sth = $dbh->prepare("SELECT `unr` AS `uid`,IF(`active` = 1 AND (`quit` IS NULL OR `quit` > CURDATE()),'yes','no') AS `mainactive` FROM `userdb`") or &sqlerr(__LINE__);
$sth->execute() or &sqlerr(__LINE__);
while (my $row = $sth->fetchrow_hashref) {
    $users{ $row->{'uid'} } = {
        'active'     => $row->{'mainactive'},
        'accounts'   => {}
    };
}
$sth->finish() or &sqlerr(__LINE__);


# Email accounts
$sth = $dbh->prepare("SELECT `unr` AS `uid`,`username` AS `local_part`,`domain`,`password`,`active`,`vacation` AS `responder_active`,`vacation_msg` AS `responder` FROM `emailaccounts` WHERE `is_alias` = 'no'") or &sqlerr(__LINE__);
$sth->execute() or &sqlerr(__LINE__);
while (my $row = $sth->fetchrow_hashref) {
    next unless exists $users{ $row->{'uid'} };
    #next unless $users{ $row->{'uid'} }{'active'} eq "yes";
    $accounts{ $row->{'domain'} }{ $row->{'local_part'} } = 1;
    next unless $row->{'active'} eq "yes";
}
$sth->finish();

$dbh->disconnect;

opendir(DIR, '/mail') || die $!;
while (my $domain = readdir DIR) {
		next if $domain =~ /^\./ || $domain eq "lost+found";
		if (!exists $accounts{ $domain }) {
				mkdir 0755, "/mail/.unused" if !-d "/mail/.unused";

				system("mv /mail/".$domain." /mail/.unused/");
				print $domain."\n";
		}
		else {
				opendir(DIR2, '/mail/'.$domain) || die $!;
				while (my $user = readdir DIR2) {
						next if $user =~ /^\./;
						if (!exists $accounts{ $domain }{ $user }) {
								mkdir 0755, "/mail/.unused" if !-d "/mail/.unused";

								mkdir 0755, "/mail/.unused/".$domain if !-d "/mail/.unused/".$domain;
								system("mv /mail/".$domain."/".$user." /mail/.unused/".$domain."/");
								print $domain."/".$user."\n";
						}
				}
				close DIR2;
		}
}
close DIR;

opendir(DIR, '/mail/.bogofilter') || die $!;
while (my $email = readdir DIR) {
    my ($user, $domain) = $email =~ /^([^\@]+)\@(.+)$/;
		next if $email =~ /^\./ || !defined $user || !defined $domain;
		if (!exists $accounts{ $domain }{ $user }) {
				mkdir 0755, "/mail/.unused" if !-d "/mail/.unused";

				system("mv /mail/.bogofilter/".$email." /mail/.unused/");
				print $email."\n";
    }
}

sub sqlerr {
    print STDERR "\n", $_[1], "\n" if defined $_[1];
    print STDERR "\nProg-Line: ",     $_[0],
                 "\n", "ErrorCode: ", $DBI::err,
                 "\n", "ErrorText: ", $DBI::errstr, "\n";
    exit;
}
__END__
