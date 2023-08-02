use utf8;

package Koha::Plugin::Com::PTFSEurope::BDS;

use Modern::Perl;
use Cwd qw( cwd abs_path);
## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;
use C4::Biblio qw( ModBiblio );

use Business::ISBN;
use Digest::MD5;
use File::Copy      qw ( move );
use File::Basename;
use List::MoreUtils qw( uniq );
use List::Util      qw( none );
use MARC::Record;
use MARC::File::USMARC;
use Net::FTP;

use Data::Dumper;

## Here we set our plugin version
our $VERSION = 1.1;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'BDS Marc Record Integrator',
    author          => 'Bernard Scaife',
    date_authored   => '2023-05-15',
    date_updated    => "2023-05-15",
    minimum_version => '21.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     =>
      'Submit isbns to BDS, retrieve results and stage / load to Koha.',
};
our $logger =
  Koha::Logger->get( { interface => 'intranet', category => 'test' } );

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);
    my $pluginsdir = C4::Context->config("pluginsdir");
    $pluginsdir = ref($pluginsdir) eq 'ARRAY' ? $pluginsdir->[0] : $pluginsdir;
    $self->{plugindir} = $pluginsdir . "/Koha/Plugin/Com/PTFSEurope/BDS/";

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            logdir              => $self->retrieve_data('logdir'),
            editracefilename    => $self->retrieve_data('editracefilename'),
            custcodeprefix      => $self->retrieve_data('custcodeprefix'),
            eancontrolmarcfield => $self->retrieve_data('eancontrolmarcfield'),
            isncontrolmarcfield => $self->retrieve_data('isncontrolmarcfield'),
            ftpaddress          => $self->retrieve_data('ftpaddress'),
            ftpeanaddress       => $self->retrieve_data('ftpeanaddress'),
            login               => $self->retrieve_data('login'),
            passwd              => $self->retrieve_data('passwd'),
            upload_isn          => $self->retrieve_data('upload_isn'),
            upload_ean          => $self->retrieve_data('upload_ean'),
            download_isn        => $self->retrieve_data('download_isn'),
            download_ean        => $self->retrieve_data('download_ean'),
            kohaframework       => $self->retrieve_data('kohaframework'),
            defaultframework    => $self->retrieve_data('defaultframework'),
            program             => $self->retrieve_data('program'),
            kohascriptpath      => $self->retrieve_data('kohascriptpath'),
        );

        $self->output_html( $template->output() );
    }
    else {
        my $logdir              = $cgi->param('logdir')              // "";
        my $editracefilename    = $cgi->param('editracefilename')    // "";
        my $custcodeprefix      = $cgi->param('custcodeprefix')      // "";
        my $eancontrolmarcfield = $cgi->param('eancontrolmarcfield') // "";
        my $isncontrolmarcfield = $cgi->param('isncontrolmarcfield') // "";
        my $ftpaddress          = $cgi->param('ftpaddress')          // "";
        my $ftpeanaddress       = $cgi->param('ftpeanaddress')       // "";
        my $login               = $cgi->param('login')               // "";
        my $passwd              = $cgi->param('passwd')              // "";
        my $upload_isn          = $cgi->param('upload_isn')          // "";
        my $upload_ean          = $cgi->param('upload_ean')          // "";
        my $download_isn        = $cgi->param('download_isn')        // "";
        my $download_ean        = $cgi->param('download_ean')        // "";
        my $kohaframework       = $cgi->param('kohaframework')       // "";
        my $defaultframework    = $cgi->param('defaultframework')    // "";
        my $program             = $cgi->param('program')             // "";
        my $kohascriptpath      = $cgi->param('kohascriptpath')      // "";
        $self->store_data(
            {
                logdir              => $logdir,
                editracefilename    => $editracefilename,
                custcodeprefix      => $custcodeprefix,
                eancontrolmarcfield => $eancontrolmarcfield,
                isncontrolmarcfield => $isncontrolmarcfield,
                ftpaddress          => $ftpaddress,
                ftpeanaddress       => $ftpeanaddress,
                login               => $login,
                passwd              => $passwd,
                upload_isn          => $upload_isn,
                upload_ean          => $upload_ean,
                download_isn        => $download_isn,
                download_ean        => $download_ean,
                kohaframework       => $kohaframework,
                defaultframework    => $defaultframework,
                program             => $program,
                kohascriptpath      => $kohascriptpath,

            }
        );
        $self->go_home();
    }
}

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('submitted') ) {
        $self->tool_step1();
    }
    else {
        #$logger->warn(Dumper($cgi));
        if ( $cgi->param('bdschoice') eq "submit" ) {
            $logger->warn("Submitting...\n");
            $self->submit_bds();
        }
        elsif ( $cgi->param('bdschoice') eq "import" ) {
            $logger->warn("Importing...\n");
            $self->import_bds();
        }
        elsif ( $cgi->param('bdschoice') eq "stage" ) {
            $logger->warn("Staging...\n");
            $self->stage_bds();
        }
        else {
            exit;
        }
    }
}

sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

 # TODO - check if config variables are set and if not warn user to do so first.
    my $template = $self->get_template( { file => 'tool-step1.tt' } );

    $self->output_html( $template->output() );
}

sub submit_bds {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'submit-bds.tt' } );
    $logger->warn("Getting keys to submit\n");
    my $keyresult = $self->get_keys_forsubmission();
    if ( $keyresult->{error} ) {
        $logger->warn( "Error: " . Dumper( $keyresult->{error} ) . "\n" );
        $template->param( error => $keyresult->{error} );
    }
    $logger->warn("Sending ISBNs to BDS\n");
    my $auresult = $self->autoresponse_ftp( { function => 'send' } );
    if ( $auresult->{error} ) {
        $logger->warn( "Error: " . Dumper( $auresult->{error} ) . "\n" );
        $template->param( error => $auresult->{error}, fn => "send" );
    }

    $self->output_html( $template->output() );
}

sub import_bds {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'import-bds.tt' } );

    $logger->warn("Receiving from BDS\n");
    my $auresult = $self->autoresponse_ftp( { function => 'receive' } );
    if ( $auresult->{error} ) {
        $logger->warn( "Error: " . Dumper( $auresult->{error} ) . "\n" );
        $template->param( error => $auresult->{error}, fn => "receive" );
    }
    $logger->warn("Fixing charsets\n");
    $self->fix_charsets();
    $logger->warn("Update autoresponse\n");
    my $uarresult = $self->update_autoresponse();
    if ( $uarresult->{error} ) {
        $logger->warn( "Error: " . Dumper( $uarresult->{error} ) . "\n" );
        $template->param( error => $uarresult->{error} );
    }

    $self->output_html( $template->output() );
}

sub stage_bds {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'stage-bds.tt' } );

    $logger->warn("Staging and loading BDS files to Koha\n");
    my $sbdsresult = $self->stage_bds_files();
    if ( $sbdsresult->{error} ) {
        $logger->warn( "Error: " . Dumper( $sbdsresult->{error} ) . "\n" );
        $template->param( error => $sbdsresult->{error} );
    }
    my $sandlresult = $self->stage_and_load();
    if ( $sandlresult->{error} ) {
        $logger->warn( "Error: " . Dumper( $sandlresult->{error} ) . "\n" );
        $template->param( error => $sandlresult->{error} );
    }

    # Convert resevoir 10 character isbns to 13-digit forms
    $logger->warn("Normalising 10 to 14 digit isbns\n");
    $self->normalize_isbns();

    $self->output_html( $template->output() );
}

sub get_keys_forsubmission {

    my ( $self, $args ) = @_;

 # scan the edi trace log for records generated from EDI quotes
 # that lack a matching bib
 # extract the search key and biblio number so that search keys can be submitted
 # to BDS

    my $logfile =
      $self->retrieve_data('logdir') . $self->retrieve_data('editracefilename');
    my $bds_dir = $self->{plugindir};
    my $date;

    if (@ARGV) {
        $date = shift;
        if ( $date !~ m/^\d{4}\/\d{2}\/\d{2}/ ) {
            say 'Invalid date passed : use format YYYY/MM/DD';
            exit 1;
        }
    }

    if ( !$date ) {
        my @t = localtime();
        $date = sprintf '%4d/%02d/%02d', $t[5] + 1900, $t[4] + 1, $t[3];
    }

    my $normalized_date = $date;
    $normalized_date =~ s#/##g;
    my @raw_keys;

    $logger->warn("Try to open EDI trace log $logfile \n");
    open( my $fh, '<', $logfile )
      or return { error => "unable to open EDI log file at $logfile" };

    my ( $key, $bib );
    while (<$fh>) {
        chomp;
        if (/^$date/) {    # eg 2021/06/22
            my $line = substr $_, 20;
            if ( $line =~ m/^Checking db for matches with ([\dXx]+)/ ) {
                $key = $1;
                undef $bib;
            }
            elsif ( $line =~ m/^New biblio added (\d+)/ ) {
                $bib = $1;
                push @raw_keys, "$key|$bib";
            }
            elsif ( $line =~ m/^Match found/ ) {
                undef $key;
            }
            elsif ( $line =~ m/^Updating bib:(\d+) id:([\dXx]+)/ )
            {    # invoice updated title
                push @raw_keys, "$2|$1";
            }
        }
    }
    close $fh;

    @raw_keys = uniq @raw_keys;    # dont submit duplicates

    if (@raw_keys) {
        my @isbns;
        my @eans;
        open( my $keys, '>', "${bds_dir}keys/${normalized_date}_keys" )
          or return { error =>
"Could not open keys_file ${bds_dir}keys/${normalized_date}_keys : $!"
          };

        foreach my $k (@raw_keys) {
            say {$keys} $k;

            my ( $skey, undef ) = split /[|]/, $k;
            if ( $skey =~ m/^97[89]/ || length($skey) == 10 ) {
                push @isbns, $skey;
            }
            else {
                push @eans, $skey;
            }
        }
        close $keys;

        my $file_date = substr $normalized_date, 4;    # monthday only
        if (@isbns) {
            my $filename = $self->retrieve_data('custcodeprefix')
              . "${normalized_date}1.TXT";
            my $isnkeysfile = $self->create_input_file(
                { filename => $bds_dir . "isbns/$filename", keys => \@isbns } );
            if ( $isnkeysfile->{error} ) {
                return { error => $isnkeysfile->{error} };
            }
        }
        if (@eans) {
            my $filename = $self->retrieve_data('custcodeprefix')
              . "T${normalized_date}1.TXT";
            my $eankeysfile = $self->create_input_file(
                { filename => $bds_dir . "eans/$filename", keys => \@eans } );
            if ( $eankeysfile->{error} ) {
                return { error => $eankeysfile->{error} };
            }
        }

    }

    return;

}

sub create_input_file {
    my ( $self, $args ) = @_;

    open( my $fh, '>', $args->{filename} )
      or return { error => "Cannot open $args->{filename}: $!" };
    foreach my $k ( @{ $args->{keys} } ) {
        say $fh $k;
    }
    close $fh;
    return;
}

sub autoresponse_ftp {
    my ( $self, $args ) = @_;
    my $retval;
    if ( $args->{function} eq 'send' ) {
        $retval = $self->submit_files( { type => 'isbns' } );
        $retval = $self->submit_files( { type => 'eans' } );
    }
    elsif ( $args->{function} eq 'receive' ) {
        $retval = $self->retrieve_files( { type => 'isbns' } );
        $retval = $self->retrieve_files( { type => 'eans' } );
    }
    else {
        return { error => "Unrecognized function : $args->{function}" };
    }

    if ( $retval->{error} ) {
        return $retval;
    }
}

sub submit_files {

    my ( $self, $args ) = @_;
    my $directory = $self->{plugindir} .  $args->{type};
    my $ftpaddr   = "";
    if ( !chdir $directory ) {
        return { error => "could not cd to $directory" };
    }
    opendir my $dh, $directory
      or return { error => "Cannot opendir $directory: $!" };
    my @submit_files =
      grep { /^$self->retrieve_data('custcodeprefix')T?\d{9}\.TXT$/ }
      readdir($dh);

    closedir $dh;

    if (@submit_files) {
        if ( $args->{type} eq "isbns" ) {
            $ftpaddr = $self->retrieve_data('ftpaddress');
        }
        else {
            $ftpaddr = $self->retrieve_data('ftpeanaddress');
        }
        my $ftp = Net::FTP->new( $ftpaddr, Debug => 0, Passive => 1 )
          or return { error => "Cannot connect to $ftpaddr: $@" };

        $ftp->login( $self->retrieve_data('login'),
            $self->retrieve_data('passwd') )
          or return { error => "Cannot login:  $ftp->message" };
        if ( $args->{type} eq "isbns" ) {
            $ftp->cwd( $self->retrieve_data('upload_isn') )
              or return {
                error => "Cannot change working directory $ftp->message" };
        }
        else {
            $ftp->cwd( $self->retrieve_data('upload_ean') )
              or return {
                error => "Cannot change working directory  $ftp->message" };
        }
        foreach my $filename (@submit_files) {
            $ftp->put($filename);
            move( "$directory/$filename", "$directory/submitted/$filename" );
        }
        $ftp->quit;

    }
    return;
}

sub retrieve_files {

    my ( $self, $args ) = @_;
    my $getf_retval;

    #my $type      = shift;
    my $directory = $self->{plugindir} .  $args->{type};
    if ( !chdir $directory ) {
        return { error => "could not cd to $directory" };
    }
    opendir my $dh, "$directory/received"
      or return { error => "Cannot opendir $directory: $!" };
    my @already_received =
      grep { /^$self->retrieve_data('custcodeprefix')?\d{9}.?\.mrc$/ }
      readdir($dh);
    closedir $dh;

    #my $f = $ftp_details->{$type};
    my $ftp = Net::FTP->new(
        $self->retrieve_data('ftpaddress'),
        Debug   => 0,
        Passive => 1
      )
      or return {
        error => "Cannot connect to  $self->retrieve_data('ftpaddress'): $@" };
    $ftp->login( $self->retrieve_data('login'), $self->retrieve_data('passwd') )
      or return { error => "Cannot login:  $ftp->message" };
    $getf_retval = $self->get_bds_files(
        {
            type             => $args->{type},
            ftp              => $ftp,
            already_received => @already_received
        }
    );
    $ftp->quit;

    return $getf_retval;

}

sub get_bds_files {

    my ( $self, $args ) = @_;

    #my ($type, $ftp, @already_received) = @_;
    my @bdsdirs;
    if ( $args->{type} eq "isbns" ) {
        @bdsdirs = split /\|/, $self->retrieve_data('download_isn');
    }
    else {
        @bdsdirs = split /\|/, $self->retrieve_data('download_ean');
    }
    my @files_on_server;
    my @download_files;
    foreach my $bdsdirectory (@bdsdirs) {
        $args->{ftp}->cwd($bdsdirectory)
          or return { error =>
              "Cannot change working directory  $args->{ftp}->message " };

        @files_on_server = $args->{ftp}->ls;
        @download_files =
          grep { /$self->retrieve_data('custcodeprefix')\d{9}.*.mrc$/ }
          @files_on_server;
        foreach my $filename (@download_files) {

            if ( none { /$filename/ } $args->{already_received} ) {
                $args->{ftp}->get($filename);
            }
        }
    }
    return;
}

sub fix_charsets {

    my ( $self, $args ) = @_;

    my $program          = $self->retrieve_data('progam');
    my $custcodeprefixlc = $self->retrieve_data('custcodeprefix');

    # eans marcfiles are encoded in MARC-8 convert to utf_8 before load

    my $directory = $self->{plugindir} .  "eans";

    opendir my $dh, $directory
      or return { error => "Cannot opendir $directory: $!" };
    my @mfiles = grep { /^$self->retrieve_data('custcodeprefix')t\d{9}\.mrc$/ }
      readdir($dh);
    closedir $dh;

    foreach my $filename (@mfiles) {
        move( "$directory/$filename", "$directory/tmp/$filename" );
        my $cmdline =
"$program -f MARC-8 -t UTF-8 -l 9=97 -o marc $directory/tmp/$filename >$directory/$filename";
        system($cmdline );
    }
}

sub update_autoresponse {

    my ( $self, $args ) = @_;
    my $directory = $self->{plugindir};

    open( my $arfh, '>>',
        $self->retrieve_data('eancontrolmarcfield') . "autoresponse.log" )
      or return { error => "Could not open file "
          . $self->retrieve_data('eancontrolmarcfield')
          . "autoresponse.log  $!" };

    my $keys = $self->get_keys( { directory => $directory } );
    our $dbh      = C4::Context->dbh;
    our $item_sth = $dbh->prepare(
q{update items set itemcallnumber = ? where biblionumber = ? and notforloan = -1}
    );

    my @marcfiles = $self->get_marcfiles( { bds_dir => $directory } );
    foreach my $marcfilename (@marcfiles) {

        my $marcfile = MARC::File::USMARC->in($marcfilename);

        while ( my $m = $marcfile->next() ) {
            my $control;
            my $control_number;
            if ( $marcfilename =~ m/ean/ ) {
                $control =
                  $m->field( $self->retrieve_data('eancontrolmarcfield') );
                $control_number = $control->subfield('a');
            }
            else {
                $control =
                  $m->field( $self->retrieve_data('isncontrolmarcfield') );
                $control_number = $control->data();
            }
            print $arfh "Rec:$control_number ";
            if ( exists $keys->{$control_number} ) {
                say "matches biblio $keys->{$control_number}";
                $self->update_biblio(
                    {
                        keys     => $keys->{$control_number},
                        m        => $m,
                        item_sth => $item_sth
                    }
                );
            }
            else {
                say "NO MATCH";
            }
        }

        $marcfile->close();
        my $received_filename = $marcfilename;
        if ( $received_filename =~ s#(isbn|ean)s#$1s/received# ) {
            move( $marcfilename, $received_filename );
        }

    }

}

sub update_biblio {
    my ( $self, $args ) = @_;

    #my ( $biblionumber, $m, $item_sth ) = @_;
    my $recid = shift;

    my $leader = $args->{m}->leader();
    my $frameworkcode =
      $self->get_framework( { framework => substr( $leader, 6, 2 ) } );

    ModBiblio( $args->{m}, $args->{biblionumber}, $frameworkcode );

    my $shelfmark = $args->{m}->field('082')->subfield('a');
    if ($shelfmark) {
        $self->update_shelfmark(
            {
                shelfmarl    => $shelfmark,
                biblionumber => $args->{biblionumber},
                item_sth     => $args->{item_sth}
            }
        );
    }

    return;
}

sub get_framework {

    my ( $self, $args ) = @_;

    my $str    = $args->{str};
    my @fcodes = ();
    @fcodes = split /\|/, $self->retrieve_data('kohaframework');

    foreach my $fcode (@fcodes) {
        if ( $fcode =~ m{^$str} ) {
            return substr( $fcode, ( index( $fcode, ":" ) + 1 ) );
        }
    }

    return $self->retrieve_data('kohaframework');
}

sub get_keys {

    my ( $self, $args ) = @_;

    #my $directory = shift;
    my $directory = $args->{directory} . 'keys';
    my $k         = {};
    opendir my $dh, $directory
      or return { error => "Cannot open $directory: $!" };
    while ( readdir $dh ) {
        if (/^\d{8}_keys/) {
            my $filename     = "$directory/$_";
            my $new_filename = "$directory/submitted/$_";
            open my $fh, '<', $filename
              or return { error => "Could not open $filename : $!" };
            while (<$fh>) {
                chomp;
                my ( $key, $biblio ) = split /\|/, $_;
                $k->{$key} = $biblio;
            }
            close $fh;
            move( $filename, $new_filename );
        }
    }
    return $k;
}

sub get_marcfiles {

    my ( $self, $args ) = @_;
    my $dir = $self->{plugindir};

    #my $bds_dir = shift;
    my @files;

    for my $subdir (qw(isbns eans)) {
        my $directory = $dir . $subdir;
        opendir my $dh, $directory
          or return { error => "Cannot open $directory: $!" };
        while ( readdir $dh ) {
            if (/^$self->retrieve_data('custcodeprefix')t?\d{9}.?\.mrc$/) {
                push @files, $dir . $subdir . "/$_";
            }
        }
        closedir $dh;
    }
    return @files;
}

sub update_shelfmark {
    my ( $self, $args ) = @_;

    #my ($sm, $b, $item_sth) = @_;
    if ( $args->{b} ) {
        $args->{item_sth}->execute( $args->{shelfmark}, $args->{b} );
    }
    return;
}

sub stage_bds_files {

    my ( $self, $args ) = @_;
    my $directory = $self->{plugindir};

    my $dlresult = $self->download_new_files();
    if ( $dlresult->{error} ) {
        return $dlresult->{error};
    }

    my $dbh = C4::Context->dbh;
    my $sql =
q|select distinct file_name from import_batches where file_name regexp "$self->retrieve_data('custcodeprefix')[0-9][0-9][0-9][0-9].mrc$" and date(upload_timestamp) > DATE_ADD(CURRENT_DATE(), INTERVAL -6 MONTH)
 order by file_name|;

    my $loaded_files = $dbh->selectcol_arrayref($sql);

    my $potential_files = $self->get_potentials();
    if ( $potential_files->{error} ) {
        return { error => $potential_files->{error} };
    }

    my %loaded = map { $_ => 1 } @{$loaded_files};

    my @files_to_load;

    foreach my $f ( @{$potential_files} ) {
        my $niaresult = $self->not_in_archive( { f => $f } );
        if ( $niaresult->{error} ) {
            return { error => $niaresult->{error} };
        }
        if ( !exists $loaded{$f} && $niaresult ) {
            push @files_to_load, $f;
        }
    }

    my $stage_file = $directory . '/Inprocess/files_to_stage';
    open my $fh, '>', $stage_file
      or return { error => "Cannot write to $stage_file : $!" };
    foreach my $f (@files_to_load) {
        print $fh $f, "\n";
    }
    close $fh;

}

sub download_new_files {

    my ( $self, $args ) = @_;
    my $directory = $self->{plugindir};

    my $local_dir = $directory . '/Source';
    opendir( my $dh, $local_dir )
      or return { error => "can't opendir $local_dir: $!" };
    my @loc_files =
      grep {
             /^$self->retrieve_data('custcodeprefix').*\.mrc$/
          && -f "$local_dir/$_"
          && -M "$local_dir/$_" < 300
      } readdir($dh);
    closedir $dh;
    my %loc_fil = map { $_ => 1 } @loc_files;

    my $remote   = $self->retrieve_data('ftpaddress');
    my $username = $self->retrieve_data('login');
    my $password = $self->retrieve_data('passwd');

    my $ftp = Net::FTP->new( $remote, Debug => 0, Passive => 1 )
      or return { error => "Cannot connect to BDS: $@" };

    $ftp->login( $username, $password )
      or return { error => 'Cannot login to BDS ', $ftp->message };
    $ftp->binary();
    my $gbdsmresult =
      $self->get_bds_marc_files( { ftp => $ftp, loc_fil => %loc_fil } );
    if ( $gbdsmresult->{error} ) {
        return { error => $gbdsmresult->{error} };
    }
    $ftp->quit;

    return;
}

sub get_bds_marc_files {

    my ( $self, $args ) = @_;

    my @bdsdirs;
    @bdsdirs = split /\|/, $self->retrieve_data('download_isn');
    my @rem_files;
    my $modt;
    foreach my $bdsdirectory (@bdsdirs) {
        $args->{ftp}->cwd($bdsdirectory)
          or return {
            error => "Cannot change working directory $args->{ftp}->message" };
        @rem_files =
          $args->{ftp}->ls( $self->retrieve_data('custcodeprefix') . '*.mrc' );
        foreach my $rmfl (@rem_files) {

            $modt = $args->{ftp}->mdtm($rmfl);

            if ( !exists( $args->{loc_fil}{$rmfl} ) ) {

                $args->{ftp}->get( $rmfl, "Source/$rmfl" );
                `touch --date=\@$modt Source/$rmfl`;
            }
        }
    }
}

sub get_potentials {

    my ( $self, $args ) = @_;
    my $directory = $self->{plugindir};

    my $local_dir = $directory . '/Source';
    opendir( my $dh, $local_dir )
      or return { error => "can't opendir $local_dir: $!" };
    my @loc_files =
      grep {
             /^$self->retrieve_data('custcodeprefix').*\.mrc$/
          && -f "$local_dir/$_"
          && -M "$local_dir/$_" < 160
      } readdir($dh);
    closedir $dh;
    my @filelist = sort @loc_files;
    return \@filelist;
}

sub not_in_archive {
    my ( $self, $args ) = @_;
    my $directory = $self->{plugindir};
    my $archive_filename = $directory . "Archive/$args->{filename}";
    if ( -f $archive_filename ) {
        open my $fh, '<', $archive_filename
          or return { error => "Cannot open $archive_filename : $!" };
        binmode $fh;
        my $archive_digest = Digest::MD5->new->addfile($fh)->hexdigest;
        close $fh;
        my $source_filename = "Source/$args->{filename}";
        open my $fh2, '<', $source_filename
          or return { error => "Cannot open $source_filename : $!" };
        binmode $fh2;
        my $source_digest = Digest::MD5->new->addfile($fh2)->hexdigest;
        close $fh2;

        # if contents do not match it is a new file
        return $source_digest ne $archive_digest ? 1 : 0;
    }
    else {
        # not present in archive
        # ok to process
        return 1;
    }
    return;
}

sub stage_and_load() {

    my ( $self, $args ) = @_;
    my $directory = $self->{plugindir};

    open( my $files_to_stage, '<', $directory . "Inprocess/files_to_stage" )
      or return { error =>
          "Could not open file" . $directory . "Inprocess/files_to_stage $!" };
    my $file_to_stage = "";
    my $batchnumber   = "";
    while (<$files_to_stage>) {
        chomp $_;
        $file_to_stage = $_;
        system( $self->retrieve_data('kohascriptpath')
              . "stage_file.pl --file " . $directory . "Source/"
              . $file_to_stage
              . " --match 1 --item-action ignore > " . $directory . "Logs/"
              . $file_to_stage
              . ".log" );
        $batchnumber =
          system( "grep '^Batch' "
              . $directory . "Logs/"
              . $file_to_stage
              . ".log | sed 's/[^0-9]//g'" );
        system( $self->retrieve_data('kohascriptpath')
              . "commit_file.pl --batch-number "
              . $batchnumber
              . " >> " . $directory . "Logs/"
              . $file_to_stage
              . ".log" );
        system("cp $file_to_stage " . $directory . "Archive/");

    }
}

sub normalize_isbns() {
    my $select_sql =
q{select import_record_id, isbn from import_biblios where length(isbn) = 10 and matched_biblionumber is null};

    my $dbh = C4::Context->dbh;

    my $sth = $dbh->prepare(
        'update import_biblios set isbn = ? where import_record_id = ?');

    my $recs = $dbh->selectall_arrayref( $select_sql, { Slice => {} } );

    foreach my $row ( @{$recs} ) {
        my $isbn = Business::ISBN->new( $row->{isbn} );
        if ( $isbn && $isbn->is_valid ) {
            $isbn = $isbn->as_isbn13;
            my $isbn13 = $isbn->as_string( [] );

            $sth->execute( $isbn13, $row->{import_record_id} );
        }
    }
}

#Supprimer le plugin avec toutes ses données
sub uninstall() {
    my ( $self, $args ) = @_;
}

1;
