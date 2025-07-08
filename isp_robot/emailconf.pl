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


$|=1;

my $debug = 0;

# Set initial modification time
my $flagfile  = "/srv/.public/confmod/email";
my $flagmtime = -f $flagfile ? (stat($flagfile))[9] : 0;


foreach (@ARGV) {
    if (/^--?d(ebug)?$/i) {
        $debug = 1;
    }
}


# Update PID File
open PID, ">/var/run/emailconf.pid";
print PID $$;
close PID;


# Verbindung zur Datenbank herstellen
my $dbh = DBI->connect("dbi:mysql:database=webhosting:host=80.153.174.96:port=43306", "webhosting", "webhosting", {
                          PrintError  => 0,
                          RaiseError  => 0
} ) or &sqlerr(__LINE__);


my %checksum;
my $sighup = 0;
my $sigint = 0;

$SIG{USR1} = sub { $sighup = 1 };
$SIG{INT} = sub { $sigint = 1 };


MAIN: while (1) {
    my $file;
    my $sth;
    my %out;
    my $out;
    my %users;
    my %domains;
    my %responder = ();
    my %addresslist;


    # load users
    $sth = $dbh->prepare("SELECT `unr` AS `uid`,IF(`active` = 1 AND (`quit` IS NULL OR `quit` > CURDATE()),'yes','no') AS `mainactive` FROM `userdb`") or &sqlerr(__LINE__);
    $sth->execute() or &sqlerr(__LINE__);
    while (my $row = $sth->fetchrow_hashref) {
        $users{ $row->{'uid'} } = {
            'active'     => $row->{'mainactive'},
            'accounts'   => {}
        };
    }
    $sth->finish() or &sqlerr(__LINE__);


    # Email accounts
    %out = ();
    $sth = $dbh->prepare("SELECT `unr` AS `uid`,`username` AS `local_part`,`domain`,`password`,`active`,`vacation` AS `responder_active`,`vacation_msg` AS `responder` FROM `emailaccounts` WHERE `is_alias` = 'no'") or &sqlerr(__LINE__);
    $sth->execute() or &sqlerr(__LINE__);
    while (my $row = $sth->fetchrow_hashref) {
        next unless exists $users{ $row->{'uid'} };
        next unless $users{ $row->{'uid'} }{'active'} eq "yes";
        $users{ $row->{'uid'} }{'accounts'}{ $row->{'local_part'}.'@'.$row->{'domain'} } = $row->{'active'};
        next unless $row->{'active'} eq "yes";

        # Check for Punycode
        my @idomain = split(/\./, $row->{'domain'});
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        $out{ $row->{'domain'} }{ $row->{'local_part'} } = $row->{'password'} ne "" ? unix_md5_crypt($row->{'password'}, "netzland") : "!";
        $domains{ $idomain } = 1;
        if ($row->{'responder_active'} eq 'yes' && $row->{'responder'} ne '') {
            $row->{'responder'} =~ s/\r/\\r/go;
            $row->{'responder'} =~ s/\n/\\n/go;
            #$responder{ $row->{'local_part'}.'@'.$idomain } = decode("utf8", $row->{'responder'});
            $responder{ $row->{'local_part'}.'@'.$idomain } = $row->{'responder'};
        }

        if (!-d "/var/mail/".$row->{'domain'}."/".$row->{'local_part'}) {
            system("/bin/su", "mail", "-c", "/bin/mkdir -m 700 /var/mail/".$row->{'domain'}) if !-d "/var/mail/".$row->{'domain'};
            system("/bin/su", "mail", "-c", "/usr/bin/maildirmake /var/mail/".$row->{'domain'}."/".$row->{'local_part'});
            system("/bin/su", "mail", "-c", "/usr/bin/maildirmake /var/mail/".$row->{'domain'}."/".$row->{'local_part'}."/.Junk-E-Mail");
            system("/bin/su", "mail", "-c", "/usr/bin/maildirmake /var/mail/".$row->{'domain'}."/".$row->{'local_part'}."/.LEARN-Spam");
            system("/bin/su", "mail", "-c", "/usr/bin/maildirmake /var/mail/".$row->{'domain'}."/".$row->{'local_part'}."/.LEARN-Good");
        }
        elsif (!-d "/var/mail/".$row->{'domain'}."/".$row->{'local_part'}."/.Junk-E-Mail") {
            system("/bin/su", "mail", "-c", "/usr/bin/maildirmake /var/mail/".$row->{'domain'}."/".$row->{'local_part'}."/.Junk-E-Mail");
            system("/bin/su", "mail", "-c", "/usr/bin/maildirmake /var/mail/".$row->{'domain'}."/".$row->{'local_part'}."/.LEARN-Spam");
            system("/bin/su", "mail", "-c", "/usr/bin/maildirmake /var/mail/".$row->{'domain'}."/".$row->{'local_part'}."/.LEARN-Good");
        }

        $addresslist{ $row->{'local_part'}.'@'.$idomain } = $row->{'uid'};
    }
    $sth->finish();

    $file = "/etc/exim/db/accounts.db";
    $out = "";
    foreach my $domain (sort keys %out) {
        # Check for Punycode
        my @idomain = split(/\./, $domain);
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        foreach my $local_part (sort keys %{ $out{ $domain } }) {
            $out .= $local_part.'@'.$idomain.':'.$out{ $domain }{ $local_part }."\n";
        }
    }
    if ($out eq "") {
        die "Will not write an empty database! aborting...";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }

    $file = "/etc/authlib/userdb.dat";
    $out = "";
    foreach my $domain (sort keys %out) {
        # Check for Punycode
        my @idomain = split(/\./, $domain);
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        foreach my $local_part (sort keys %{ $out{ $domain } }) {
            $out .= $local_part.'@'.$idomain."\t".
                     "uid=8".
                    "|gid=12".
                    "|home=/var/mail/".$domain."/".$local_part.
                    "|mail=/var/mail/".$domain."/".$local_part."\n";
        }
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/lib/courier-imap/makedatprog - /tmp/userdb.tmp /etc/authlib/userdb.dat" or die "$!";
        print PH $out.".\n";
        close PH;
        print "done.\n";
        $checksum{$file} = md5_hex($out);
    }

    $file = "/etc/authlib/userdbshadow.dat";
    $out = "";
    foreach my $domain (sort keys %out) {
        # Check for Punycode
        my @idomain = split(/\./, $domain);
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        foreach my $local_part (sort keys %{ $out{ $domain } }) {
            $out .= $local_part.'@'.$idomain."\t".
                    "systempw=".$out{ $domain }{ $local_part }."\n";
        }
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/lib/courier-imap/makedatprog - /tmp/userdb.tmp /etc/authlib/userdbshadow.dat" or die "$!";
        print PH $out.".\n";
        close PH;
        print "done.\n";
        $checksum{$file} = md5_hex($out);
    }

    # E-Mail Auto-Responder
    $file = "/etc/exim/db/auto_responder.db";
    $out = "";
    foreach (sort keys %responder) {
        $out .= $_.":".$responder{ $_ }."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    # Aliases
    %out = ();
    my %forwards_extern;
    my %remote_smtp;
    $sth = $dbh->prepare("SELECT `unr` AS `uid`,REPLACE(`username`,'\@','*') AS `local_part`,`domain`,`alias` AS `address` FROM `emailaccounts` WHERE `is_alias` = 'yes' AND `active` = 'yes'") or &sqlerr(__LINE__);
    $sth->execute() or &sqlerr(__LINE__);
    while (my $row = $sth->fetchrow_hashref) {
        next unless exists $users{ $row->{'uid'} };
        next unless $users{ $row->{'uid'} }{'active'} eq "yes";
        next if exists $users{ $row->{'uid'} }{'accounts'}{ $row->{'local_part'}.'@'.$row->{'domain'} } && $users{ $row->{'uid'} }{'accounts'}{ $row->{'local_part'}.'@'.$row->{'domain'} } eq "no";
        next if exists $users{ $row->{'uid'} }{'accounts'}{ $row->{'address'} } && $users{ $row->{'uid'} }{'accounts'}{ $row->{'address'} } eq "no" && (!exists $users{ $row->{'uid'} }{'accounts'}{ $row->{'local_part'}.'@'.$row->{'domain'} } || $users{ $row->{'uid'} }{'accounts'}{ $row->{'local_part'}.'@'.$row->{'domain'} } eq "no");

        # Check for Punycode
        my @idomain = split(/\./, $row->{'domain'});
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        $domains{ $idomain } = 1;

        if ($row->{'address'} =~ /^smtp:(.+)$/) {
            $remote_smtp{ $row->{'local_part'}.'@'.$idomain } = [] if !exists $remote_smtp{ $row->{'local_part'}.'@'.$idomain };
            push @{ $remote_smtp{ $row->{'local_part'}.'@'.$idomain } }, $1;
        }
        else {
            $out{ $row->{'local_part'}.'@'.$idomain } = [] if !exists $out{ $row->{'local_part'}.'@'.$idomain };
            push @{ $out{ $row->{'local_part'}.'@'.$idomain } }, $row->{'address'};
        }

        $addresslist{ $row->{'local_part'}.'@'.$idomain } = $row->{'uid'};
    }
    $sth->finish();

    $file = "/etc/exim/db/aliases.db";
    $out = "";
    foreach (sort keys %out) {
        $out .= $_.":".join(",", sort @{ $out{$_} })."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }

    $file = "/etc/exim/db/remote_smtp.db";
    $out = "";
    foreach (sort keys %remote_smtp) {
        $out .= $_.":".join(",", sort @{ $remote_smtp{$_} })."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    # Addresslist
    $file = "/etc/exim/db/addresslist.db";
    $out = "";
    foreach (sort keys %addresslist) {
        $out .= $_.":".$addresslist{$_}."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    # Domains
    $file = "/etc/exim/db/domains.db";
    $out = "";
    foreach (sort keys %domains) {
        $out .= $_."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    # Spmassassin
    %out = ();
    $sth = $dbh->prepare("SELECT `unr` AS `uid`,CONCAT(`username`,'\@',`domain`) AS `address`,`spam_kill_level` AS `score` FROM `emailaccounts` WHERE `is_alias` = 'no' AND `active` = 'yes' AND `spam_kill_level` > 0") or &sqlerr(__LINE__);
    $sth->execute() or &sqlerr(__LINE__);
    while (my $row = $sth->fetchrow_hashref) {
        next unless exists $users{ $row->{'uid'} };
        next unless $users{ $row->{'uid'} }{'active'} eq "yes";

        $out{ $row->{'address'} } = $row->{'score'};
    }
    $sth->finish();

    $file = "/etc/exim/db/check_spam.db";
    $out = "";
    foreach (sort keys %out) {
        $out .= $_.":"."+"x$out{$_}."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    # Bogofilter
    %out = ();
    $sth = $dbh->prepare("SELECT `unr` AS `uid`,CONCAT(`username`,'\@',`domain`) AS `address`,NULL AS `bogodirectory` FROM `emailaccounts` WHERE `is_alias` = 'no' AND `active` = 'yes' AND `spamcheckprofi` = 'yes'") or &sqlerr(__LINE__);
    $sth->execute() or &sqlerr(__LINE__);
    while (my $row = $sth->fetchrow_hashref) {
        next unless exists $users{ $row->{'uid'} };
        next unless $users{ $row->{'uid'} }{'active'} eq "yes";

        my ($local_part, $domain) = $row->{'address'} =~ /^(.+)\@([^\@]+)$/;

        # Check for Punycode
        my @idomain = split(/\./, $domain);
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        my $src_address = $local_part.'@'.$idomain;
        my $dst_address = $local_part.'@'.$idomain;

        if (defined $row->{'bogodirectory'} && length($row->{'bogodirectory'})) {
            my ($local_part, $domain) = $row->{'bogodirectory'} =~ /^(.+)\@([^\@]+)$/;

            # Check for Punycode
            my @idomain = split(/\./, $domain);
            for (my $i = 0; $i < @idomain-1; $i ++) {
                $idomain[$i] = encode_punycode($idomain[$i]);
            }
            my $idomain = join(".", @idomain);
            undef @idomain;

            $dst_address = $local_part.'@'.$idomain;
        }

        $out{ $src_address } = $dst_address;
    }
    $sth->finish();

    $file = "/etc/exim/db/bogofilter.db";
    $out = "";
    foreach (sort keys %out) {
        $out .= $_.":".$out{$_}."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    # Spamdestination
    %out = ();
    $sth = $dbh->prepare("SELECT `unr` AS `uid`,CONCAT(`username`,'\@',`domain`) AS `address`,NULL AS `spamdst` FROM `emailaccounts` WHERE `is_alias` = 'no' AND `active` = 'yes' AND `spamcheckprofi` = 'yes'") or &sqlerr(__LINE__);
    $sth->execute() or &sqlerr(__LINE__);
    while (my $row = $sth->fetchrow_hashref) {
        next unless exists $users{ $row->{'uid'} };
        next unless $users{ $row->{'uid'} }{'active'} eq "yes";

        my ($local_part, $domain) = $row->{'address'} =~ /^(.+)\@([^\@]+)$/;

        # Check for Punycode
        my @idomain = split(/\./, $domain);
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        my $src_address = $local_part.'@'.$idomain;
        my $dst_address = $local_part.'@'.$idomain;

        if (defined $row->{'spamdst'} && length($row->{'spamdst'})) {
            my ($local_part, $domain) = $row->{'spamdst'} =~ /^(.+)\@([^\@]+)$/;

            # Check for Punycode
            my @idomain = split(/\./, $domain);
            for (my $i = 0; $i < @idomain-1; $i ++) {
                $idomain[$i] = encode_punycode($idomain[$i]);
            }
            my $idomain = join(".", @idomain);
            undef @idomain;

            $dst_address = $local_part.'@'.$idomain;
        }

        $out{ $src_address } = $dst_address;
    }
    $sth->finish();

    $file = "/etc/exim/db/spamdst.db";
    $out = "";
    foreach (sort keys %out) {
        $out .= $_.":".$out{$_}."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    # Spamcheck+ DCC
    %out = ();
if (0) {
    $sth = $dbh->prepare("SELECT `unr` AS `uid`,CONCAT(`username`,'\@',`domain`) AS `address` FROM `emailaccounts` WHERE `is_alias` = 'no' AND `active` = 'yes' AND `spamcheckprofi` = 'yes'") or &sqlerr(__LINE__);
    $sth->execute() or &sqlerr(__LINE__);
    while (my $row = $sth->fetchrow_hashref) {
        next unless exists $users{ $row->{'uid'} };
        next unless $users{ $row->{'uid'} }{'active'} eq "yes";

        my ($local_part, $domain) = $row->{'address'} =~ /^(.+)\@([^\@]+)$/;

        # Check for Punycode
        my @idomain = split(/\./, $domain);
        for (my $i = 0; $i < @idomain-1; $i ++) {
            $idomain[$i] = encode_punycode($idomain[$i]);
        }
        my $idomain = join(".", @idomain);
        undef @idomain;

        my $src_address = $local_part.'@'.$idomain;
        my $dst_address = $local_part.'@'.$idomain;

        $out{ $src_address } = 1;
    }
    $sth->finish();
}

    $file = "/etc/exim/db/dcc.db";
    $out = "";
    foreach (sort keys %out) {
        $out .= $_.":".$out{$_}."\n";
    }
    if (!exists $checksum{$file} || $checksum{$file} ne md5_hex($out)) {
        print scalar(localtime)." (".$file."): ";
        open PH, "|/usr/sbin/exim_dbmbuild - \"".$file."\"" or die "$!";
        print PH $out;
        close PH;
        $checksum{$file} = md5_hex($out);
    }


    last if $debug;

    my $startwait = time();
    for (my $I = $startwait; time() < $startwait+60; $I ++) {
        sleep(2); # warten...

        if (-f $flagfile) {
            my $mtime = (stat($flagfile))[9];
            if ($mtime != $flagmtime) {
                $flagmtime = $mtime;
                next MAIN;
            }
        }

        if ($sighup) {
            print scalar(localtime)." SIGUSR1 received.\n";
            $dbh->disconnect;
            exec $0;
        }
        if ($sigint) {
            print scalar(localtime)." SIGINT received.\n";
            last MAIN;
        }
    }
}


$dbh->disconnect;

unlink "/var/run/emailconf.pid";


sub sqlerr {
    print STDERR "\n", $_[1], "\n" if defined $_[1];
    print STDERR "\nProg-Line: ",     $_[0],
                 "\n", "ErrorCode: ", $DBI::err,
                 "\n", "ErrorText: ", $DBI::errstr, "\n";
    exit;
}
__END__
