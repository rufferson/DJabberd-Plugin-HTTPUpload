#!/usr/bin/perl
use 5.008;
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME => 'DJabberd::Component::HTTPUpload',
	VERSION_FROM => 'lib/DJabberd/Component/HTTPUpload.pm',
	ABSTRACT_FROM => 'lib/DJabberd/Component/HTTPUpload.pm',
	PREREQ_PM => {
		'DJabberd' => '0.85',
		'DJabberd::Delivery::OfflineStorage' => '0.0.1'
	},
	AUTHOR => 'Ruslan N. Marchenko <me@ruff.mobi>',
);
