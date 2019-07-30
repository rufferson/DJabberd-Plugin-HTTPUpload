#!/usr/bin/perl -wT
# vim: sts=4 ai:
use strict;
#
#
package DJabberd::External::HTTPUpload;
use CGI::Fast;
use CGI;
use DBI;
use Data::Dumper;
#

sub new {
    return bless {};
}

sub main_loop {
    my $self = shift;
    while($self->{cgi} = CGI::Fast->new) {
	#print STDERR Dumper(\%ENV);
	#print STDERR Dumper($self->{cgi});
	$ENV{PATH_INFO} =~ /([^.\/]+\.\w+)/;
	my $file = $1;
	$ENV{SCRIPT_NAME} =~ /([^\/.]+)/;
	my $path = $1;
	$ENV{X_DATA_DIR} =~ /^(\/[a-zA-Z\/_-]+)$/;
	my $data = $1;
	$ENV{X_DB_FILE} =~ /^(\/[a-zA-Z\/_-]+\.?\w*)$/;
	my $base = $1;
	$self->{db} = DBI->connect_cached("dbi:SQLite:dbname=$base","","",
	    {
		RaiseError  =>1,
		#ReadOnly    =>1,
		AutoCommit  =>1
	    });
	if($ENV{REQUEST_METHOD} eq 'PUT') {
	    my $expire = ($ENV{X_SLOT_TIME} || 60);
	    my $sth = $self->{db}->prepare_cached("SELECT type FROM files WHERE key=? AND file=? AND size=? AND ts > datetime(?,'unixepoch') AND put IS null");
	    my $key;
	    if($ENV{HTTP_BEARER}) {
		$ENV{HTTP_BEARER} =~ /([^.\/]+)/;
		$key = $1;
	    } elsif($ENV{HTTP_COOKIE}) {
		$ENV{HTTP_COOKIE} =~ /key=([^;.\/]+);/;
		$key = $1;
	    } else {
		$key = $path;
	    }
	    my $ret = $sth->execute($key, $file, $ENV{CONTENT_LENGTH}, (time - $expire)) && $sth->fetch;
	    print STDERR "Fetch result: key='$key' AND file='$file' AND size='$ENV{CONTENT_LENGTH}' AND ts > datetime('".(time-$expire)."','unixepoch') => ".Dumper($ret);
	    if($ret && (!$ret->[0] || $ret->[0] eq $ENV{CONTENT_TYPE})) {
		$sth->finish;
		if(mkdir("$data/$key",0770)) {
		    my $fh;
		    if(open($fh,">","$data/$key/$file") && binmode($fh) && 
			syswrite($fh,$self->{cgi}->param('PUTDATA')) == $ENV{CONTENT_LENGTH})
		    {
			print "Status: 201\n";
			print "\nFile $file is stored under $path\n";
			close($fh);
			$sth = $self->{db}->prepare_cached("UPDATE files SET put=datetime('now') WHERE key=? AND file=?");
			if($sth->execute($key, $file)) {
			    $sth->finish;
			}
			next;
		    }
		}
		print "Status: 500\n";
		print "\nFailed to upload $file to $path: $!\n";
	    } else {
		print "Status: 403\n";
		print "\nFile $file is not allowed at $path\n";
	    }
	} else {
	    my $sth = $self->{db}->prepare_cached("SELECT key,size,type FROM files WHERE uid=? AND file=? AND put is not null");
	    my $ret = $sth->execute($path,$file) && $sth->fetch;
	    my $fh;
	    if($ret && open($fh,"<","$data/$ret->[0]/$file") && binmode($fh)) {
		my $type = $ret->[2] || 'application/octet-stream';
		print "Status: 200\n";
		print "Content-Length: ".$ret->[1]."\n";
		print "Content-Type: $type\n\n";
		my $buf;
		while(read($fh,$buf,4096)) {
		    print $buf;
		}
		$sth->finish;
		next;
	    }
	    print "Status: 404\n";
	    print "\nFile $file is not found at $path\n";
	}
    }
}

package main;

my $fcgi = DJabberd::External::HTTPUpload->new();

exit $fcgi->main_loop;
