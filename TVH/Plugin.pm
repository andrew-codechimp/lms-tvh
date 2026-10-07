package Plugins::TVH::Plugin;

#use strict;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TVH::API;
use Plugins::TVH::Settings;
use Plugins::TVH::Prefs;
use Plugins::TVH::EPG;
use Slim::Formats::RemoteMetadata;

use LWP::Simple;

use Data::Dumper;

my $prefs = preferences('plugin.TVH');

use vars qw($VERSION);

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.TVH',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_TVH',
} );

sub initPlugin {
	my $class = shift;

	Plugins::TVH::Settings->new;

	$VERSION = $class->_pluginDataFor('version');

	# Default the preferences
	$prefs->init({
		port => '9981',
		stationsorting => 'NAME',
	});

	# Add EPG now/next info to TVHeadend streams without changing how they play
	Slim::Formats::RemoteMetadata->registerProvider(
		match => qr{/stream/channel/},
		func  => \&Plugins::TVH::EPG::metadataProvider,
	);

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'TVH',
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
}

sub getDisplayName { 'PLUGIN_TVH' }
sub playerMenu {}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if (!$client) {
		$cb->([{ name => cstring($client, 'NO_PLAYER_FOUND') }]);
		return;
	}

	# Validate that all settings have values
	if (!$prefs->get('server')||!$prefs->get('port')) {
		$cb->([{ name => cstring($client, 'PLUGIN_TVH_NO_SETTINGS') }]);
		return;
	}

	$client = $client->master;

	# my $items = [
	# 	{
	# 		name => cstring($client, 'PLUGIN_TVH_TAGS'),
	# 		type => 'link',
	# 		url  => \&tags,
	# 	},{
	# 		name => cstring($client, 'PLUGIN_TVH_RECORDINGS'),
	# 		type => 'link',
	# 		url  => \&recordings,
	# 	}
	# ];

	my $items = [];
	Plugins::TVH::API->getTags(sub {
		my ($tags) = @_;

		foreach (@$tags) {
			my ($tag) = $_;
			push @$items, {
				name => $_->{val},
				url => \&getStationsByTag,
				passthrough => [{
					uuid => $_->{key}
				}],
			}
		}

		@$items = sort {$a->{name} cmp $b->{name}} @$items;

		$cb->({
			items => $items,
		});
	});
}

# sub tags {
# 	my ($client, $cb, $params) = @_;
#
# 	Plugins::TVH::API->getTags(sub {
# 		my ($tags) = @_;
#
# 		my $items = [];
# 		foreach (@$tags) {
# 			my ($tag) = $_;
# 			push @$items, {
# 				name => $_->{val},
# 				url => \&getStationsByTag,
# 				passthrough => [{
# 					uuid => $_->{key}
# 				}],
# 			}
# 		}
#
# 		@$items = sort {$a->{name} cmp $b->{name}} @$items;
#
# 		$cb->({ items => $items });
# 	});
# }

# sub recordings {
# 	my ($client, $cb, $params) = @_;
#
# 	Plugins::TVH::API->getRecordings(sub {
# 		my ($recordings) = @_;
#
# 		my $items = _renderRecordings($recordings);
#
# 		$cb->({ items => $items });
# 	});
# }

sub getStationsByTag {
	my ($client, $cb, $params, $args) = @_;
	my $tagUuid = $params->{uuid} || $args->{uuid};

	Plugins::TVH::API->getStations(sub {
		my ($stations) = @_;

		if (ref $stations ne 'ARRAY') {
			$cb->({ items => [{ name => 'Could not reach TVHeadend', type => 'text' }] });
			return;
		}

		# One extra request gets "what's on now" for every channel
		Plugins::TVH::API->getEpgNow(sub {
			my ($events) = @_;

			my %nowOn;
			if (ref $events eq 'ARRAY') {
				my $now = time();
				for my $e (@$events) {
					next unless $e->{channelUuid} && $e->{title};
					next if $e->{start} && $e->{start} > $now;
					next if $e->{stop}  && $e->{stop}  <= $now;
					$nowOn{ $e->{channelUuid} } = $e;
				}
			}

			my $items = _renderStations($stations, $tagUuid, \%nowOn);

			if ($prefs->get('stationsorting') eq 'NAME') {
				@$items = sort { lc($a->{name}) cmp lc($b->{name}) } @$items;
			}
			else {
				@$items = sort { ($a->{_number} || 0) <=> ($b->{_number} || 0) } @$items;
			}

			delete $_->{_number} for @$items;

			$cb->({
				items => $items
			});
		});
	});
}

sub _renderStations {
	my ($stations, $tag, $nowOn) = @_;
	$nowOn ||= {};

	my $items = [];

	for my $station (@$stations) {
		my $tags = $station->{tags};
		next unless ref $tags eq 'ARRAY' && grep { $_ eq $tag } @$tags;

		my $uuid  = $station->{uuid};
		my $image = _getStationImage($station->{icon_public_url});

		# Remember name/logo so the player can show them while playing
		Plugins::TVH::EPG->setChannelInfo($uuid, {
			name   => $station->{name},
			number => $station->{number},
			icon   => $image,
		});

		my $prog = $nowOn->{$uuid};
		my $line2 = $prog ? 'Now: ' . $prog->{title} : ($station->{number} ? 'Channel ' . $station->{number} : '');

		push @$items, {
			name    => $station->{name},
			line1   => $station->{name},
			line2   => $line2,
			_number => $station->{number},
			type    => 'audio',
			image   => $image,
			url     => Plugins::TVH::EPG->streamUrlFor($uuid),
		};
	}

	return $items;
}

# sub _renderRecordings {
# 	my ($recordings) = @_;
#
# 	my $items = [];
#
# 	foreach (@$recordings) {
#		
# 		push @$items, {
# 			name => $_->{disp_title},
# 			line1 => $_->{disp_title},
# 			line2 => $_->{channelname},
# 			type => 'audio',
# 			image => Plugins::TVH::Prefs::getApiUrlNoAuth() . $_->{icon_public_url},
# 			url => Plugins::TVH::Prefs::getApiUrl() . $_->{url}
# 			}
# 	}
#
# 	return $items;
# }

# Logo URLs are checked once and remembered, so big station lists don't
# stall LMS by re-checking every logo on every visit.
my %imageCache;

sub _getStationImage {
	my ($path) = @_;
	return 'plugins/TVH/html/images/radio.png' unless $path;

	my $image = Plugins::TVH::Prefs::getApiUrlNoAuth() . $path;

	if (!exists $imageCache{$image}) {
		$imageCache{$image} = head($image) ? $image : 'plugins/TVH/html/images/radio.png';
	}

	return $imageCache{$image};
}

1;
