#!/usr/bin/perl

# Export Yammer group content as a strfile(1) file
# Copyright 2014, Lubomir Rintel <lkundrak@v3.sk>

# You can redistribute it and/or modify it under the terms of the
# GNU Affero General Public License, version 3
# <http://www.gnu.org/licenses/agpl-3.0.html>

use strict;
use warnings;

our $client_id = 'FILLMEIN';
our $client_secret = 'FILLMEIN';

use CGI;
require LWP::Protocol::https;
use LWP::UserAgent;
use JSON;
use URI;
use URI::Escape;
require bytes;

binmode *STDOUT, ':utf8';

local our $q = new CGI;
local our $code = $q->param ('code');
local our $token = $q->param ('token');
local our $group_id = $q->param ('group_id');

local our $root = new URI ('https://www.yammer.com/');
local our $ua = new LWP::UserAgent;
$ua->default_header (Accept => 'application/json');

sub req
{
	my $uri = new URI (shift)->abs ($root);
	$uri->query_form (@_);

	# Try to rate limit message fetches
	if ($uri =~ /messages/) {
		our $last_time ||= 0;
		my $time = time - $last_time;
		sleep 3 - $time if $time < 3;
		$last_time = time;
	}

	my $res = $ua->get ($uri);

	# Rate limiting kicked in
	# It should not -- the above should make sure it won't
	if ($res->code == 429) {
		sleep 3;
		# Retry
		$res = $ua->request ($res->request);
	}

	die $res->status_line unless $res->is_success;
	return decode_json $res->decoded_content;
}

# Redirect to OAuth authenticator
sub authenticate
{
	my $auth_uri = "https://www.yammer.com/dialog/oauth?client_id=$client_id";

	# These need to be injected artifically, as mod_perl's CGI module
	# would generate a redundant payload for us. Shame.
	print "Location: $auth_uri\r\n";
	print "Status: 302 Please Authenticate\r\n";
	print "Content-Type: text/html; charset=>utf-8\r\n\r\n";

	print $q->start_html ('Log in to Yammer');
	print $q->h1 ('Please log in to fff Yammer');
	print $q->a ({ href => $auth_uri }, 'Log in');
	print $q->end_html;
	exit;
}

# List known groups with export links
sub groups
{
	print $q->header (-type => 'text/html', -charset => 'utf-8');
	print $q->start_html ('Pick a group');
	print $q->h1 ('Please pick a Group');
	print $q->start_ul;
	foreach my $group (@{req ('/api/v1/users/current.json',
		include_group_memberships => 'true')->{group_memberships}})
	{
		my $uri = new URI;
		$uri->query_form (token => $token, group_id => $group->{id});
		print $q->li ($q->a ({ href => $uri}, $group->{name}),
			$group->{description});
	}
	print $q->end_ul;
	print $q->end_html;
	exit;
}

# Obtain the authenticaion token
if (not $token) {
	authenticate unless $code;

	$token = eval { req ('/oauth2/access_token.json',
		client_id => $client_id, client_secret => $client_secret,
		code => $code)->{access_token}{token} };

	authenticate unless $token;
}
$ua->default_header (Authorization => "Bearer $token");

# Get a group number
groups unless $group_id;

# The export itself
print $q->header (-type => 'text/plain', -charset => 'utf-8',
	'-transfer-encoding' => 'chunked');

my $oldest_id;
do {
	my @extra;
	@extra = (older_than => $oldest_id) if $oldest_id;
	my $uri = sprintf '/api/v1/messages/in_group/%s.json',
		uri_escape ($group_id);

	my @messages = @{req ($uri, @extra)->{messages}};
	$oldest_id = @messages ? $messages[$#messages]->{id} : undef;

	foreach my $msg (grep { $_->{message_type} eq 'update'
		and not $_->{replied_to_id} } @messages)
	{
		my $text = "%\n$msg->{body}{plain}\n";
		printf "%x\r\n%s\r\n", bytes::length ($text), $text;
	}

	flush STDOUT;
} while ($oldest_id);

# Chunking trailer
print "0\r\n\r\n";
exit;
