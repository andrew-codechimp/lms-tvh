package Plugins::TVH::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TVH::Prefs;

use constant CACHE_TTL => 3600;

use Scalar::Util qw(blessed dualvar isdual readonly refaddr reftype
                        tainted weaken isweak isvstring looks_like_number
                        set_prototype);

my $prefs = preferences('plugin.TVH');


my $log = logger('plugin.TVH');
my $cache = Slim::Utils::Cache->new();

sub getStations {
	my ($class, $cb) = @_;
	_call('/api/channel/grid?limit=500', $cb);
}

sub getTags {
	my ($class, $cb) = @_;
	_call('/api/channeltag/list', $cb);
}

sub getRecordings {
	my ($class, $cb) = @_;
	_call('/api/dvr/entry/grid_finished?limit=500', $cb);
}

sub getEpg {
	my ($class, $cb, $channel) = @_;
	_call("/api/epg/events/grid?limit=1&channel=${channel}", $cb);
}

# Current + upcoming programmes for one channel (sorted/filtered by the caller)
sub getEpgForChannel {
	my ($class, $cb, $channel) = @_;
	_call("/api/epg/events/grid?limit=10&sort=start&dir=ASC&channel=${channel}", $cb);
}

# What's on now across every channel, in a single request (used for browse menus)
sub getEpgNow {
	my ($class, $cb) = @_;
	_call('/api/epg/events/grid?mode=now&limit=2000', $cb);
}

sub _call {
	my ( $url, $cb, $params ) = @_;

	# $uri must not have a leading slash
	$url =~ s/^\///;
	$url = Plugins::TVH::Prefs::getApiUrl(). $url;

	if ( my @keys = sort keys %{$params}) {
		my @params;
		foreach my $key ( @keys ) {
			next if $key =~ /^_/;
			push @params, $key . '=' . $params->{$key};
			# push @params, $key . '=' . uri_escape_utf8( $params->{$key} );
		}

		$url .= '?' . join( '&', sort @params ) if scalar @params;
	}

	# my $cached;
	# my $cache_key;
	# if (!$params->{_nocache}) {
	# 	$cache_key = md5_hex($url);
	# }

	# main::INFOLOG && $log->is_info && $cache_key && $log->info("Trying to read from cache for $url");

	# if ( $cache_key && ($cached = $cache->get($cache_key)) ) {
	# 	main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url");
	# 	# main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
	# 	$cb->($cached);
	# 	return;
	# }
	# elsif ( main::INFOLOG && $log->is_info ) {
	 	main::DEBUGLOG && $log->is_debug && $log->debug("API call: $url");
	# }

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');

			my $result;

			if ( $response->headers->content_type =~ /json/i ) {
				main::INFOLOG && $log->is_info && $log->info('TVH got a response: ' . $response->content);
				$result = eval{ from_json($response->content) };
			}
			else {
				$log->error("TVHeadend didn't return JSON data? " . $response->content);
			}

			# main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			
			if ($result && $result->{entries}) {
				$result = $result->{entries};

				# if ( $cache_key ) {
				# 	if ( my $cache_control = $response->headers->header('Cache-Control') ) {

				# 		my $ttl = CACHE_TTL;

				# 		if ($ttl) {
				# 			main::INFOLOG && $log->is_info && $log->info("Caching result for $ttl using max-age (" . $response->url . ")");
				# 			$cache->set($cache_key, $result, $ttl);
				# 			main::INFOLOG && $log->is_info && $log->info("Data cached (" . $response->url . ")");
				# 		}
				# 	}
				# }
			}

			$cb->($result);
		},
		sub {
			my ($http, $error, $response) = @_;

			$log->error("Got error': $error");

			# main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
			$cb->({
				error => 'Unexpected error: ' . $error,
			}, $response);
		},
	)->get($url);
}

1;