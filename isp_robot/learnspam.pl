#!/usr/bin/perl
#
# SPAM/HAM lernen
#
#   (c) 2014 Netzland Ltd  programmed by Juergen Weiss
#       All rights reserved.
#       Last update 10.07.2014

use strict;
use DBI qw(:sql_types);
use DBD::mysql;
use MIME::Head;
use Email::Valid;
use DB_File;

# Verbindung zur Datenbank herstellen
my $dbh = DBI->connect("dbi:mysql:database=webhosting:host=80.153.174.96:port=43306", "webhosting", "webhosting", {
                          PrintError  => 0,
                          RaiseError  => 0
} ) or &sqlerr(__LINE__);


my %addrlist;

my $sth = $dbh->prepare("SELECT `unr` AS `uid`,CONCAT(`username`,'\@',`domain`) AS `address`,NULL AS `bogodirectory` FROM `emailaccounts` WHERE `is_alias` = 'no' AND `active` = 'yes' AND `spamcheckprofi` = 'yes'") or &sqlerr(__LINE__);
$sth->execute() or &sqlerr(__LINE__);
while (my $row = $sth->fetchrow_hashref) {
    my ($local_part, $domain) = split(/@/, $row->{'address'});
    $addrlist{ $domain }{ $local_part } = $row->{'bogodirectory'};
}
$sth->finish();

$dbh->disconnect;

foreach my $dom (keys %addrlist) {
    open FH, '/usr/bin/find /var/mail/'.$dom.'/*/.LEARN-{Spam,Good}/{new,cur}/ -maxdepth 1 -type f 2>/dev/null|' or die "Kann Befehl nicht ausfuehren: $!\n";
    while (<FH>) {
        s/\n$//o;
        if (my ($path,$domain,$local_part,$learn,$new_cur,$filename) = /^(\/var\/mail\/([^\/]+)\/([^\/]+))\/\.LEARN-(Spam|Good)\/(new|cur)\/(.+)$/o) {
            if (exists($addrlist{ $domain }{ $local_part })) {
                my $bogodirectory = '/var/mail/.bogofilter/'.(defined($addrlist{ $domain }{ $local_part }) ? $addrlist{ $domain }{ $local_part } : $local_part.'@'.$domain).'/';
                my $finalfile = $path.'/'.($learn eq 'Spam' ? '.Junk-E-Mail/' : '').$new_cur.'/'.$filename;
                my $rc;
open LOGFILE, ">>/var/log/isprobot/learn_spam.log" or die "Can't open logfile: $!";
print LOGFILE scalar(localtime), ": Learning ".$_." to ".$learn." (";
                for (my $I = 0; $I < 5; $I++) {
                    system('/usr/bin/bogofilter', '-p', '-d', $bogodirectory, $learn eq 'Spam' ? '-Ns' : '-Sn', '-I', $_, '-O', $finalfile);
                    $rc = $? >> 8;
print LOGFILE $I > 0 ? "," : "", $rc;
                    last if $rc == ($learn eq 'Spam' ? 0 : 1);
                }
print LOGFILE ")";
                my $mtime = (stat)[9];
                utime $mtime, $mtime, $finalfile;
                chmod 0660, $finalfile;

								my $head = MIME::Head->from_file($_);
								my $from;
								chomp($from = $head->get('Return-Path'));
								#chomp(my $from = $head->get('From'));
								chomp($from = $head->get('From')) if !defined $from;
								$from =~ s/^.*\<([^\>]*)\>.*$/$1/s;
								if (Email::Valid->address($from) ? 'yes' : 'no') {
										tie my %db, 'DB_File', '/etc/exim/db/whitelist.db', O_RDWR|O_CREAT, 0644, $DB_HASH or die "Cannot open /etc/exim/db/whitelist.db: $!\n";
										if ($learn eq 'Spam') {
												if ($from =~ /\@(.+)$/ && exists $db{ $local_part.'@'.$domain."\0" }) {
														my $address_list = $db{ $local_part.'@'.$domain."\0" };
														$address_list =~ s/\0$//;
														my @address_list = split(/:/, $address_list);
														my %hash;
														@hash{@address_list} = 1;
														if (exists $hash{$1}) {
																delete $hash{$1};
																$db{ $local_part.'@'.$domain."\0" } = join(":", keys %hash)."\0";
print LOGFILE ' DE-WHITELISTED:*@'.$1;
														}
												}
										}
										else {
												my %hash;
												if (exists $db{ $local_part.'@'.$domain."\0" }) {
														my $address_list = $db{ $local_part.'@'.$domain."\0" };
														$address_list =~ s/\0$//;
														my @address_list = split(/:/, $address_list);
														@hash{@address_list} = 1;
												}
												if (defined $head->get('X-Netzland-Callout') && $from =~ /\@(.+)$/) {
														$hash{ $1 } = 1;
print LOGFILE ' WHITELISTED:*@'.$1;
												}
												else {
														$hash{ $from } = 1;
print LOGFILE ' WHITELISTED:'.$from;
												}
												$db{ $local_part.'@'.$domain."\0" } = join(":", keys %hash)."\0";
										}
										untie %db;
								}

                unlink unless $rc == 3; # loesche die gelernte Datei wenn kein Fehler aufgetreten ist
print LOGFILE " finished\n";
close LOGFILE;
            }
        }
    }
    close FH;
}


sub sqlerr {
    print STDERR "\n", $_[1], "\n" if defined $_[1];
    print STDERR "\nProg-Line: ",     $_[0],
                 "\n", "ErrorCode: ", $DBI::err,
                 "\n", "ErrorText: ", $DBI::errstr, "\n";
    exit;
}
__END__
