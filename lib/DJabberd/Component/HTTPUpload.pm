package DJabberd::Component::HTTPUpload;
use base DJabberd::Component;
use warnings;
use strict;

use constant {
    NSHU0 => 'urn:xmpp:http:upload:0',
    NSXHU => 'urn:xmpp:http:upload',
    NSCHU => 'eu:siacs:conversations:http:upload',
    NSERR => 'urn:ietf:params:xml:ns:xmpp-stanzas'
};
our $logger = DJabberd::Log->get_logger();

=head1 NAME

DJabberd::Component::HTTPUpload - Implements XEP-0363 HTTP File Upload

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

sub run_after  { qw(DJabberd::Delivery::Local) }
sub run_before { qw(DJabberd::Delivery::S2S) }

=head1 SYNOPSIS

Implements XEP-0363 HTTP File Upload.

    <VHost mydomain.com>
	<Plugin DJabberd::Component::HTTPUpload>
	    host www
	    url https://www.mydomain.com/xmpp/upload/
	    quota 100Mb
	    max 10485760
	    dbfile /srv/http/djabberd/upload.sqlite
	</Plugin>
    </VHost>


=over

=item host

A hostname prefix to be used for a compnent. Prepended to the VHost's domain.

=item url

Specifies a base for upload path. Is appended with unique upload id and file
name to build final upload/download URL. Does not need to match host.domain
eg. could be arbitrary URL which allows upload to slots opened by this
component - which means should be hosted on this server.

=item quota

Per-user quota of file storage, in MB. 0 means no limit. When quota is
reached no new uploads are allowed for the given user.

=item max

Maximum allowed file size for upload. In bytes. Files exceeding this size
are not allowed to acquire a slot. 0 means no limitation.

=item dbfile

A path to sqlite3 db file to be used by this component and http fcgi upload
plugin. When not set component ignores the slot allocation requests.

=back

=cut


sub set_config_host {
    my ($self,$host) = @_;
    $self->{host} = $host;
}

sub set_config_url {
    my ($self, $url) = @_;
    $self->{url} = $url 
	if($url =~ /(ht|sf|f)tps?:\/\/[a-zA-Z0-9.-]+(:\d+)?\/(\w\/){0,}/no);
}

sub set_config_quota {
    $_[0]->{quota} = 0 + $_[1];
}

sub set_config_max {
    $_[0]->{quota} = 0 + $_[1];
}

sub set_config_dbfile {
    my ($self, $file) = @_;
    $self->{file} = $file;
}

sub check_quota {
    my ($self,$user) = @_;
    return eval {
	$self->{db}->selectrow_array("SELECT sum(size) FROM files WHERE user=? and put is not null",undef,$user);
    };
}

sub new_slot {
    my ($self, $user, $req) = @_;
    my $uid = DJabberd::JID::rand_resource;
    my $key = DJabberd::JID::rand_resource;
    eval {
	$self->{db}->do("INSERT INTO files(user,file,type,size,uid,key) VALUES(?,?,?,?,?,?)",
		undef,$user,$req->{name},$req->{type},$req->{size},$uid,$key);
    };
    return () if($@);
    return ($uid,$key);
}

sub parse_req {
    my $req = shift;
    my $ns = $req->namespace;

    return {
	size => $req->attr("{$ns}size"),
	name => $req->attr("{$ns}filename"),
	type => $req->attr("{$ns}content-type")
    };
}
sub parse_old {
    my $req = shift;
    my $ns = $req->namespace;

    my @kids = $req->children_elements;
    my ($size_el) = grep{$_->element_name eq 'size'}@kids;
    my ($name_el) = grep{$_->element_name eq 'filename'}@kids;
    my ($type_el) = grep{$_->element_name eq 'content-type'}@kids;

    return {
	name => ($name_el && $name_el->innards_as_xml),
	size => ($size_el && $size_el->innards_as_xml),
	type => ($type_el && $type_el->innards_as_xml)
    };
}

sub gen_slot {
    my $req = shift;
    my $url = shift;
    my $pub = shift;
    my $key = shift;
    my $ns = shift;
    return DJabberd::XMLElement->new($ns, 'slot', {},
	[
	    DJabberd::XMLElement->new($ns, 'put',
		{ url => "$url/$pub/$req->{name}" },
		[
		    DJabberd::XMLElement->new($ns, 'header',
			{ name => 'Bearer' },
			[],
			$key
		    )
		]
	    ),
	    DJabberd::XMLElement->new($ns, 'get',
		{ url => "$url/$pub/$req->{name}" },
	    )
	]
    );
}
sub gen_old_slot {
    my $req = shift;
    my $url = shift;
    my $pub = shift;
    my $key = shift;
    my $ns = shift;
    return DJabberd::XMLElement->new('', 'slot', { xmlns => $ns },
	[
	    DJabberd::XMLElement->new('', 'put', {},["$url/$key/$req->{name}"]),
	    DJabberd::XMLElement->new('', 'get', {},["$url/$pub/$req->{name}"])
	]
    );
}
sub process {
    my $self = shift;
    my $iq = shift;
    my $parser = shift;
    my $sloter = shift;
    my ($rsp,$err,$err_el,$err_msg,$retry);
    if($self->vhost->handles_jid($iq->from_jid)) {
	my $req = $parser->($iq->first_element);
	if(!$self->{max} || $req->{size} < $self->{max}) {
	    my $user = $iq->from_jid->as_bare_string;
	    if(!$self->{quota} || $self->check_quota($user) < $self->{quota}) {
		my ($pub,$key) = $self->new_slot($user, $req);
		if($pub && $key) {
		    $rsp = $iq->make_response;
		    $rsp->push_child($sloter->($req,$self->{url},$pub,$key,$iq->first_element->namespace));
		} else {
		    $err = 'modify';
		    $err_el = 'internal-server-error';
		    $err_msg = 'Slot allocation failed';
		}
	    } else {
		$err = 'wait';
		$err_el = 'resource-constraint';
		$err_msg = 'Quota reached. Retry later after older uploads expire';
		$retry = time + 300;
	    }
	} else {
	    $err = 'modify';
	    $err_el = 'not-acceptable';
	    $err_msg = 'File is too big, try to reduce it below '.$self->{max};
	}
    } else {
	$err = 'cancel';
	$err_el = 'not-allowed';
	$err_msg = 'residents only';
    }
    $rsp = $self->erply($iq, $err,$err_el, $err_msg, $retry) if($err);
    $rsp->deliver($self->vhost);
}
sub finalize {
    my ($self, $opts) = @_;
    $self->{host} ||= 'upload';
    $self->{max} ||= 1024 * 1024 * 10;
    
    $self->SUPER::finalize;

    return unless($self->{file} && $self->{url});

    $self->{db} = DBI->connect_cached("dbi:SQLite:dbname=".$self->{file},"","",
	    {AutoCommit=>1,RaiseError=>1});
    $self->{db}->do("CREATE TABLE IF NOT EXISTS files (
	fileid	INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
	user	VARCHAR(255) NOT NULL,
	file	VARCHAR(255) NOT NULL,
	type	VARCHAR(255),
	size	INTEGER NOT NULL,
	uid	VARCHAR(64) NOT NULL,
	key	VARCHAR(64),
	ts	DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	put	DATETIME DEFAULT NULL,
		UNIQUE(uid)
    )");
    return unless($self->{db});
    my $handler = sub {
	my ($vh,$iq) = @_;
	$self->process($iq,\&parse_req,\&gen_slot);
    };
    my $legacy_handler = sub {
	my ($vh,$iq) = @_;
	$self->process($iq,\&parse_old,\&gen_old_slot);
    };
    $self->register_iq_handler('get-{'.NSCHU.'}request',$legacy_handler);
    $self->register_iq_handler('get-{'.NSXHU.'}request',$legacy_handler);
    $self->register_iq_handler('get-{'.NSHU0.'}request',$handler);
}

sub features {
    my $self = shift;
    my $ftrs = $self->SUPER::features(@_);
    push(@{$ftrs},NSHU0,NSXHU,NSCHU);
    return $ftrs;
}

sub identities {
    my $self = shift;
    my $idts = $self->SUPER::identities(@_);
    push(@{$idts},['store','file','HTTP Server']);
    return $idts;
}

sub erply {
    my ($self, $iq, $err, $err_el, $err_msg, $retry) = @_;
    my $e = DJabberd::XMLElement->new('','error',
	    {type=>$err},
	    [ DJabberd::XMLElement->new(NSERR,$err_el,{},[]) ]
    );
    $e->push_child(DJabberd::XMLElement->new(NSERR,'text',{},[],$err_msg)) if($err_msg);
    $e->push_child(
	    DJabberd::XMLElement->new(NSHU0,'retry',{stamp=>DJabberd::Util::Time($retry)})
	    ) if($retry);
    $err = $iq->make_response;
    $err->push_child($iq->first_element);
    $err->push_child($e);
    return $err;
}

sub domain {
    my $self = shift;
    return $self->{host}.".".$self->vhost->server_name;
}

sub vcard {
    my ($self, $requester_jid) = @_;

    return "<N>".$self->domain."</N><FN>Web Services</FN>";
}

=head1 AUTHOR

Ruslan N. Marchenko, C<< <me at ruff.mobi> >>

=head1 COPYRIGHT & LICENSE

Copyright 2016 Ruslan N. Marchenko, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
1;
# vim: sts=4 ai:
