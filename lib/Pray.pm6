module Pray;

use Pray::Scene;
use Pray::Scene::Color;
use Pray::Output;

# in the interest of simplicity, the rendering loop currently resides here with preview and file IO written into it directly - this is more or less the "front end" for the moment
# a more generic rendering loop should be implemented in Scene, and this should be refactored with appropriate separation of concerns and future concurrency in mind
# scene param should accept a filename, a hash, or a scene instance object
# output param should be optional and we should return the results instead of writing to a file if output is not specified
# output could also be passed an array ref to be filled in with colors...or a routine to call for each pixel

our sub render (
	$scene_file,
	$out_file,
	Int $width is copy,
	Int $height is copy,
	Bool :$quiet = True,
	#Bool :$verbose = False,
	Bool :$preview = !$quiet
) {
	if !$height {
		if $width {
			$height = $width;
		} else {
			die 'Width and/or height must be specified';
		}
	} elsif !$width {
		$width = $height;
	}
	
	my $scene = Pray::Scene.load($scene_file);

	$*ERR.say('Initializing') unless $quiet;
	
	my $out = Pray::Output.new(:$width, :$height);

	my $start_time = now;

	my $count = $width * $height;

	$*ERR.say('Segmenting') unless $quiet;
	
	my $threads = 2;
	my $sched = ThreadPoolScheduler.new(
		max_threads => $threads
	);

	my $range = [min] 256, $count div $threads + ?( $count % $threads );
	my @parts;
	my $last = $count - 1;
	my %context;
	while !@parts || @parts[*-1][1] < $last {
		my $start = @parts ?? @parts[*-1][1]+1 !! 0;
		my $end = [min] $start + $range - 1, $last;
		eager hilbert_coord($width, $height, $start, :%context);
		@parts.push: [ $start, $end, Hash.new(eager %context).item ];
	}
	
	my $channel = Channel.new;
	
	$*ERR.say('Rendering') unless $quiet;

	while @parts {
		my $part = @parts.shift;
		$sched.cue: {
			sink for $part[0]..$part[1] -> $i {
				my $point = eager hilbert_coord\
					( $width, $height, $i, :context( $part[2] ) );
				
				my $color = $scene.screen_coord_color\
					( $point[0], $point[1], $width, $height );
				
				$channel.send: ($point, $color).item;
			}
			# return here causes the thread to die with an error
				# TODO reduce & report
		};
	}

	while $out.incomplete {
		my $msg = $channel.receive;
		my ($point, $color) = @$msg;
		$out.set(
			$point[0], $point[1],
			$color.r, $color.g, $color.b,
			:$preview
		);
	};

	$channel.close;

	# preview leaves cursor at end of last line to avoid scrolling the output
	$*ERR.say('') if $preview; 

	$*ERR.say("Writing to $out_file") unless $quiet;
	$out.write_ppm($out_file);
	$*ERR.say('Exiting') unless $quiet;
}

#convert d to (x,y)
# seeking version to support fast near indexing without memory bloat
# caching the whole sequence was too slow and memory-intensive
sub hilbert_coord ($w, $h, $i, :%context! is rw) {
	#say %context.perl if %context;
	unless %context {
		my $max = [max] $w, $h;
		my $dec_size = log($max) / log(2);
		my $hilbert_size = Int($dec_size);
		$hilbert_size++ if $hilbert_size < $dec_size;
		$hilbert_size = 2 ** $hilbert_size;
		%context = (
			size => $hilbert_size,
			offset => 0,
			count => $w * $h,
			index => 0
		);
	}
	
	my $dir = +( $i <=> %context<index> );
	
	my $coord;
	until $coord {
		my $test_coord = Any;
		while
			!$test_coord ||
			$test_coord[0] >= $w ||
			$test_coord[1] >= $h
		{
			%context<offset> += $dir;
			
			die "Hilbert offset %context<offset> outside of %context<size>² area\n" ~
				"i:$i\td:$dir\n" ~
				"{%context.perl}\n" ~
				"last tested: {($test_coord // []).perl}"
				unless
					%context<offset> >= 0 &&
					%context<offset> < %context<size> ** 2;
			
			$test_coord = hilbert_dist( %context<size>, %context<offset> );
		}
		
		%context<index> += $dir;
		
		$coord = $test_coord if %context<index> == $i;
	}

	return @$coord;
}

# copied and ported from wikipedia
# http://en.wikipedia.org/wiki/Hilbert_curve#Applications_and_mapping_algorithms
# assumes square of $n x $n size, $n = a power of two (2, 4, 8, 16, etc)
# $d is a 0-based integer index into the sequence ( 0 <= $d < $n ** 2 )
sub hilbert_dist ($n, $d) {
	my ($rx, $ry, $s, $t);
	$t = $d;
	my ($x, $y) = 0, 0;
	
	loop ($s=1; $s < $n; $s *= 2) {
		$rx = 1 +& ( $t / 2 );
		$ry = 1 +& ( $t +^ $rx );
		&hilbert_coord_rot($s, $x, $y, $rx, $ry);
		$x += $s * $rx;
		$y += $s * $ry;
		$t /= 4;
	}
	return $x, $y;
}
 
# from same source as above
# rotate/flip a quadrant appropriately
sub hilbert_coord_rot ($n, $x is rw, $y is rw, $rx, $ry) {
	if ($ry == 0) {
		if ($rx == 1) {
			$x = $n-1 - $x;
			$y = $n-1 - $y;
		}
 
		#Swap x and y
		($x, $y) = $y, $x;
	}
	return;
}
