package HtDig::Database;

# $Id: Database.pm,v 1.3 2000/04/20 17:22:32 wjones Exp $
# $Source: /home/wjones/src/CVS.repo/htdig/local-additions/Database/Database.pm,v $

require 5.000;

use strict;
use Exporter;
use Carp;
use vars qw( $VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS );

# Load Compress::Zlib if possible, but it's not
# an error if compression is not available.

if ( eval { require Compress::Zlib } ) {
    import Compress::Zlib;
}

# Constants used in URL encoding (see HtWordCodec.cc):

$VERSION     = 0.52;
@ISA         = qw( Exporter );
@EXPORT      = ();
@EXPORT_OK   = qw( get_config parse_docdb encode_url decode_url );
%EXPORT_TAGS = ( 'all' => [ @EXPORT_OK ] );

# These strings are used as hash keys, and correspond to
# integer field codes in the docdb data structure.
# The order is important:

my @fields = qw(
	ID TIME ACCESSED STATE SIZE LINKS IMAGESIZE HOPCOUNT
	URL HEAD TITLE DESCRIPTIONS ANCHORS EMAIL NOTIFICATION
	SUBJECT STRING METADSC BACKLINKS SIG
);

# These are the string fields and the list fields.
# All remaining fields are integers.

my %string_fields = map { $_, 1 } qw(
	URL HEAD TITLE EMAIL NOTIFICATION SUBJECT STRING METADSC
);

my %list_fields = map { $_, 1 } qw( DESCRIPTIONS ANCHORS );


# These variables are used by &encode_url and &decode_url:

use constant FIRST_INTERNAL_SINGLECHAR =>  7;
use constant  LAST_INTERNAL_SINGLECHAR => 31;

my ( @url_parts, %url_parts, $url_parts );
my @default_url_parts = qw(
    http:// http://www. ftp:// ftp://ftp. /pub/
    .html .htm .gif .jpg .jpeg /index.html /index.htm
    .com/ .com mailto:
);

my $matchchars = sprintf '[\0%o-\0%o]', FIRST_INTERNAL_SINGLECHAR,
				         LAST_INTERNAL_SINGLECHAR;
my $maxparts = LAST_INTERNAL_SINGLECHAR -
	       FIRST_INTERNAL_SINGLECHAR + 1;
my $warning  = '';

sub set_url_parts {	# Setup for variables used by
			# &encode_url and &decode_url
    my $code = FIRST_INTERNAL_SINGLECHAR;
    %url_parts = map { $_, chr($code++) } @url_parts = @_;
    $url_parts = join '|', map { quotemeta($_) } @_;
    $warning = "Too many common_url_parts: can't handle more than $maxparts.\n"
        if $#url_parts > $maxparts;
}

set_url_parts( @default_url_parts );	# Initialize with defaults.

sub getnum {			# Extract integer from doc doc record.
    my ( $flags, $in ) = @_;
    my ( $fmt, $length ) = ( 'I', 4 );
       ( $fmt, $length ) = ( 'C', 1 ) if $flags & 0100;
       ( $fmt, $length ) = ( 'S', 2 ) if $flags & 0200;
    $_[1] = substr($in,$length+1);
    unpack($fmt,substr($in,1)); 
}

sub getstring {			# Extract string from doc record.
    my $length = getnum( @_ );
    my $string = substr( $_[1], 0, $length );
    $_[1] = substr( $_[1], $length );
    return $string;
}

sub getlist {			# Extract list from doc record.
    my ( $flags, $in ) = @_;
    my $count = getnum( $flags, $in );
    my @list = ();
    for ( my $i=0; $i<$count; $i++ ) {
	my $length = 255;
	if ( $flags ) {
	    $length = unpack('C',$in); 
	    $in = substr($in,1);
	}
	if ( $length > 253 ) {
	    $length = unpack('I',$in);
	    $in = substr($in,4);
	}
	push @list, substr($in,0,$length);
	$in = substr($in,$length);
    }
    $_[1] = $in;
    return \@list;
}

sub parse_docdb
{
    my $record = shift;
    my %record = (); 
    while ( length($record) > 0 ) {
	my $code  = unpack('C', $record);
	my $flags = $code & 0300;
	$code &= 077;
	if ( $code > $#fields ) {
	    carp "Invalid item code: $code";	
	    last;
	}
	my $field = $fields[$code];
	my $value;
	if ( $list_fields{$field} ) {
	    $value = getlist($flags,$record);
	} elsif ( $string_fields{$field} ) {
	    $value = getstring($flags,$record);
	    $value = decode_url($value) if $field eq 'URL';
	    if ( $field eq 'HEAD' && substr($value,0,2) eq "x\234" ) {
                 if ( defined &inflateInit ) {
		    my ( $i, $zstatus ) = inflateInit();
		    ( $value, $zstatus ) = $i->inflate($value);
		 }
		 else {
		     $value = 'Compressed data: Zlib not available';
		 }
	    }

	} else {
	    $value = getnum($flags,$record);
	}
	return $value if $_[0] && $_[0] eq $field;
	$record{$field} = $value;
    }
    return $_[0] ? '' : %record;
}

sub decode_url {
    local($_) = shift;
    if ( $warning ) {
        carp $warning;
    }
    else {
	s/$matchchars/$url_parts[ord($&)-&FIRST_INTERNAL_SINGLECHAR]/oeg;
    }
    $_;
}

sub encode_url {
    local($_) = shift;
    if ( $warning ) {
	carp $warning;
    }
    else {
	s/($url_parts)/$url_parts{$&}/eg;
    }
    $_;
}

sub get_config {
#
#   The first argument is the name of an htdig config file.
#   The second parameter, if present, is a hash ref that is
#   to receive the config values.  The second parameter is
#   used only for recursive calls in the case of included files.
#   A hash ref is returned on success, or undef if the file
#   cannot be opened.
#
    my $file   = shift;
    my $config = shift || {};
    no strict 'refs';
    if ( ! open $file, $file ) {
	return undef;
    }
    while ( <$file> ) {
        $_ .= <$file> while s/\\\n/ / && ! eof($file);
	next if /^\s*(#|$)/;
	( my $key, $_ ) = /^\s*(\w+)\s*:\s*(.*)/;
	if ( ! $key ) {
	    carp "Syntax error in $file (line $.)";
	    next;
	}
	s/\${(\w+)}/$config->{$1} || ''/ge;	# variable substitution
	s/`([^`]+)`/file_contents($1,$file)/ge;	# file substitution
	if ( $key eq 'include' ) {
	    $_ = "$1/$_" if ! m|^/| && $file =~ m|(.*)/|;
	    get_config( $_, $config );
	}
	else {
	    $config->{$key} = $_;
	}
    }
    close $file;
    use strict 'refs';
    my $parts = $config->{common_url_parts};
    set_url_parts( defined($parts) ? split( ' ', $parts ) :
    				     @default_url_parts		);
    $warning .= "URL translation can't handle url_part_aliases.\n"
        if $config->{url_part_aliases};
    return $config;
}

sub file_contents {
#
#   Return the contents of a file, with newlines
#   replaced by a single space.
#
    if ( ! open FILE, $_[0] ) {
        carp "Can't access included file $_[0] at $_[1] line $.";
	return '';
    }
    my @file_contents = map { chomp, $_ } <FILE>;
    close FILE;
    return "@file_contents";
}

1;
__END__

=head1 NAME

Htdig::Database - Perl interface Ht://Dig docdb and config files

=head1 SYNOPSIS

    use Htdig::Database;

    my $config = Htdig::Database::get_config( $config_file )
	    or die "$0: Can't access $config_file\n";
    my $record = Htdig::Database::parse_docdb( $docdb_record );
    print "URL = $record->{URL}\n";

=head1 DESCRIPTION

=head2 Exported functions

The following functions are provided by Htdig::Database:

    get_config
    parse_docdb
    encode_url
    decode_url

By default, functions are not exported into the callers namespace,
and you must invoke them using the full package name, e.g.:

    Htdig::Database::getconfig( $config_file );

To import all available function names, invoke the module with:

    use Htdig::Database qw(:all);

=head2 Parsing a config file

C<get_config> parses a config file and returns a hash ref that
contains the configuration attributes.  For example:

    my $config = Htdig::Database::get_config( $config_file )
	or die "$0: Can't access $config_file\n";
    print "start_url = $config->{start_url}\n";

All values in the hash are scalars, and any items that are intended
to be lists or booleans must be parsed by the calling program.
C<get_config> returns C<undef> if the config file can't be opened,
and carps about various syntax errors.

=head2 Parsing a record from the document database

C<parse_docdb> parses a record from the document database
and returns a hash ref.  For example:

    my %docdb;
    tie( %docdb, 'DB_File', $docdb, O_RDONLY, 0, $DB_BTREE ) ||
	die "$0: Unable to open $docdb: $!";

    while ( my ( $key, $value ) = each %docdb ) {
	next if $key =~ /^nextDocID/;
        my %rec = Htdig::Database:parse_docdb( $value );
	print "     URL: $record->{URL}\n";
	print "HOPCOUNT: $record->{HOPCOUNT}\n";
    }

URL's in the database are encoded using two attributes from the
configuration file: I<common_url_parts> and I<url_part_aliases>.
C<parse_docdb> does only rudimentary decoding.  It can't
handle more than 25 elements in the I<common_url_parts> list,
and it currently can't handle I<url_part_aliases> at all.

C<get_config> caches the value of I<common_url_parts> that's
used for decoding URL's, and should usually be called before
C<parse_docdb>.

Compressed data in the HEAD element will be automatically decompressed
if the Compress::Zlib module is available.  If Compress::Zlib is not
installed, compressed data will be silently replaced by the string:

    "Compressed data: Zlib not available"

If only a single value is needed from the database record,
it can be specified as a second parameter to C<parse_docdb>,
which then returns the requested value as a scalar.  For example:

    my $url = Htdig::Database:parse_docdb( $value, 'URL' );

=head2 Encoding a URL

    my $encoded_url = Htdig::Database::encode_url( $url );

This may be useful for computing database keys, since the keys
are encoded URL's.  C<get_config> should be called before C<encode_url>
or C<decode_url> to initialize the value of C<common_url_parts>.

=head2 Decoding a URL

    my $url = Htdig::Database::decode_url( $encoded_url );

This should seldom be necessary, since URL's are normally
decoded by C<parse_docdb>.

=head1 AUTHOR

Warren Jones E<lt>F<wjones@halcyon.com>E<gt>

=head1 BUGS

Only simple cases of URL encoding are handled correctly.
No more than 25 elements are allowed in I<common_url_parts>.
The value of I<url_part_aliases> is not used at all.
Someday this module may implement the same URL encoding
logic found in F<HtWordCodec.cc>, but a better solution might
be to provide an XSUB interface to the C++ functions.

This module works with ht://Dig 3.1.4.  It probably works
with 3.1.5, though this hasn't been tested.  Because of changes
in the database format, it I<will not work> with version 3.2.

=cut
