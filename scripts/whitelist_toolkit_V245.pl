#!/usr/bin/perl
use strict;
use warnings;
use Fcntl;
use DB_File;
use File::Copy;

my %db;
my $filename = "whitelist_clean.db";
my $txtfile  = "whitelist_clean.txt";

sub show_menu {
    print <<"END_MENU";

==== 🚀 Whitelist Toolkit v2.4.5 ====
1. 🔍 Teilstring-Suche (Lookup)
2. ➕ From-Adresse zu bestehendem Empfänger hinzufügen
3. 🆕 Neuer Empfänger mit From-Adressen
4. 🗑️  Empfänger löschen
5. 📄 Als .txt exportieren
6. 📏 From-Zähler & Zeichenzähler (aus .db)
7. 📥 Import: .txt → .db (Perl tie)
8. 🛠️  exim_dbmbuild: .txt → .db (Exim-native)
9. 🧪 Preflight: Zeichenzahl-Check auf .txt
0. 🛑 Beenden
🧭 Auswahl:
END_MENU
}

sub load_db {
    untie %db if %db;
    tie %db, "DB_File", $filename, O_CREAT | O_RDWR, 0644, $DB_HASH or die "DB kann nicht geladen werden: $!";
}

sub save_txt {
    load_db();
    open my $fh, '>:encoding(UTF-8)', $txtfile or die $!;
    foreach my $rcpt (sort keys %db) {
        my @froms = grep { $_ ne '' } split /[:,;]/, $db{$rcpt};
        my $clean = join(",", sort @froms);
        $clean =~ s/\x00//g;
        print $fh "$rcpt:$clean\n";
    }
    close $fh;
    print "✅ Exportiert nach $txtfile\n";
    untie %db;
}

sub import_txt {
    unless (-e $txtfile) {
        print "❌ Datei $txtfile nicht gefunden. Exportiere zuerst mit Option 5.\n";
        return;
    }

    my %new;
    open my $fh, '<:encoding(UTF-8)', $txtfile or die $!;
    while (<$fh>) {
        chomp;
        my ($rcpt, $froms) = split /:/, $_, 2;
        next unless $rcpt and $froms;
        $rcpt  =~ s/\x00//g;
        $froms =~ s/\x00//g;
        $froms =~ s/[:,;]/,/g;
        $froms =~ s/,+/,/g;
        $froms =~ s/(^,|,$)//g;
        $new{$rcpt} = $froms;
    }
    close $fh;

    if (-e $filename) {
        copy($filename, "$filename.bak." . time);
    }

    untie %db if %db;
    tie %db, "DB_File", $filename, O_CREAT | O_RDWR, 0644, $DB_HASH or die $!;
    %db = %new;
    untie %db;
    print "✅ Import abgeschlossen: $txtfile → $filename\n";
}

sub exim_dbmbuild {
    unless (-e $txtfile) {
        print "❌ Datei $txtfile nicht gefunden. Bitte zuerst Option 5 ausführen.\n";
        return;
    }

    my $out;
    open my $fh, '<:encoding(UTF-8)', $txtfile or die $!;
    while (<$fh>) {
        chomp;
        next unless /:/;
        my ($rcpt, $froms) = split /:/, $_, 2;
        $rcpt  =~ s/\x00//g;
        $froms =~ s/\x00//g;
        $froms =~ s/[:,;]/,/g;
        $froms =~ s/,+/,/g;
        $froms =~ s/(^,|,$)//g;
        $out .= "$rcpt:$froms\n";
    }
    close $fh;

    if (-e $filename) {
        copy($filename, "$filename.bak." . time);
        print "🔐 Backup gespeichert.\n";
    }

    my $cmd = "/usr/sbin/exim_dbmbuild - \"$filename\"";
    open my $pipe, "| $cmd" or die "❌ exim_dbmbuild fehlt oder schlägt fehl!\n";
    print $pipe $out;
    close $pipe;

    print "✅ exim_dbmbuild erfolgreich → $filename\n";
}

sub search_key {
    load_db();
    print "🔍 Teilbegriff: ";
    chomp(my $s = <STDIN>);
    foreach my $rcpt (grep { /$s/i } keys %db) {
        print "→ $rcpt: $db{$rcpt}\n";
    }
    untie %db;
}

sub add_from {
    load_db();
    print "Empfänger-Adresse (Key): ";
    chomp(my $rcpt = <STDIN>);
    print "Neue From-Adresse(n) (Komma-separiert): ";
    chomp(my $froms = <STDIN>);
    my %seen;
    $seen{$_}++ for grep { $_ } split /[:,;]/, $db{$rcpt}, $froms;
    $db{$rcpt} = join(",", sort keys %seen);
    print "✅ From-Adressen aktualisiert für $rcpt\n";
    untie %db;
}

sub new_entry {
    load_db();
    print "Neue Empfänger-Adresse: ";
    chomp(my $rcpt = <STDIN>);
    print "From-Adresse(n) (Komma-separiert): ";
    chomp(my $froms = <STDIN>);
    $db{$rcpt} = join(",", sort grep { $_ } split /[:,;]/, $froms);
    print "✅ Eintrag erstellt: $rcpt\n";
    untie %db;
}

sub delete_entry {
    load_db();
    print "Empfänger zum Löschen: ";
    chomp(my $del = <STDIN>);
    if (exists $db{$del}) {
        delete $db{$del};
        print "🗑️  $del gelöscht\n";
    } else {
        print "❌ Kein Eintrag gefunden für $del\n";
    }
    untie %db;
}

sub recipient_value_stats {
    load_db();
    foreach my $rcpt (sort keys %db) {
        my $froms = $db{$rcpt};
        my @senders = grep { $_ ne '' } split /[:,;]/, $froms;
        my $anzahl = scalar @senders;
        my $zeichen = length($froms);
        printf "📨 %-40s → %4d Froms | %5d Zeichen\n", $rcpt, $anzahl, $zeichen;
        if ($zeichen > 19999) {
            print "⚠️  WARNUNG: Value-Zeichenanzahl > 19999 bei $rcpt\n";
        }
    }
    untie %db;
}

sub analyze_txt_file {
    unless (-e $txtfile) {
        print "❌ Datei $txtfile nicht gefunden.\n";
        return;
    }

    open my $fh, '<:encoding(UTF-8)', $txtfile or die $!;
    print "\n📊 Preflight-Analyse der Empfängerzeilen (TXT-Version):\n";
    my $warn = 0;

    while (<$fh>) {
        chomp;
        my ($rcpt, $froms) = split /:/, $_, 2;
        next unless $rcpt and defined $froms;
        $rcpt  =~ s/\x00//g;
        $froms =~ s/\x00//g;
        my @from_list = grep { $_ ne '' } split /[:,;]/, $froms;
        my $count = scalar @from_list;
        my $length = length($froms);
        printf "📨 %-40s → %4d Froms | %5d Zeichen\n", $rcpt, $count, $length;
        if ($length > 19999) {
            print "⚠️  Überlänge! -> $rcpt überschreitet 19999 Zeichen\n";
            $warn++;
        }
    }

    close $fh;
    print "✅ Analyse abgeschlossen. $warn potenziell problematische Zeilen gefunden.\n\n";
}

# 🔁 Hauptloop
while (1) {
    show_menu();
    chomp(my $choice = <STDIN>);
    if    ($choice eq '1') { search_key() }
    elsif ($choice eq '2') { add_from() }
    elsif ($choice eq '3') { new_entry() }
    elsif ($choice eq '4') { delete_entry() }
    elsif ($choice eq '5') { save_txt() }
    elsif ($choice eq '6') { recipient_value_stats() }
    elsif ($choice eq '7') { import_txt() }
    elsif ($choice eq '8') { exim_dbmbuild() }
    elsif ($choice eq '9') { analyze_txt_file() }
    elsif ($choice eq '0') { print "🛑 Beendet.\n"; last }
    else { print "❓ Ungültige Auswahl\n"; }
}
