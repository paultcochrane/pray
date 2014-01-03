use v6;

use Pray::Geometry::Vector3D;
use Pray::Geometry::Ray;
use Pray::Scene::Color;

class Pray::Scene::Lighting {
	has Pray::Scene::Color $.color = white;
	has Real $.intensity = 1;
	has Pray::Scene::Color $.color_scaled = $!color.scale($!intensity);

	method color_shaded () { $!color_scaled };
}

class Pray::Scene::Ambiance is Pray::Scene::Lighting {}

class Pray::Scene::Diffusion is Pray::Scene::Lighting {
	multi method color_shaded (
		Pray::Scene::Color $light_color,
		Real :$cos!,
	) {
		self.color_scaled.scale($cos).scale($light_color)
	}

	multi method color_shaded (
		Pray::Scene::Color $light_color,
		$int,
		Pray::Geometry::Vector3D $light_dir,
	) {
		self.color_shaded(
			$light_color,
			cos => $int.direction.dot($light_dir)
		)
	}
}

class Pray::Scene::Specularity is Pray::Scene::Lighting {
	has Real $.sharpness = 100;

	method color_shaded (
		Pray::Scene::Color $light_color,
		$int,
		Pray::Geometry::Vector3D $light_dir,
	) {
		my $reflect_dir = $light_dir.reflect($int.direction);
		my $specular = $reflect_dir.reverse.dot($int.ray.direction);

		if $specular > 0 {
			$specular **= $!sharpness
				if $specular != 1;

			$specular =
				self.color_scaled\
				.scale($specular).scale($light_color);

			return $specular;
		} else {
			return black;
		}
	}
}

class Pray::Scene::Reflection is Pray::Scene::Lighting {
	method color_shaded (
		$int,
		:$recurse,
	) {
		my $reflect_dir = $int.ray.direction\
			.reflect($int.direction).scale(-1);
		my $reflect_ray = Pray::Geometry::Ray.new(
			position => $int.position,
			direction => $reflect_dir
		);
		
		my $reflect_color = $int.scene.ray_color(
			$reflect_ray,
			recurse => $recurse,
			containers => $int.containers,
		);
		
		return $reflect_color.scale(self.color_scaled);
	}
}

class Pray::Scene::Transparency is Pray::Scene::Lighting {
	has Real $.refraction;
	
	method color_shaded (
		$int,
		:$recurse
	) {
		#refractive index when we're not inside any object
		my $ambient_ri = 1; # move this to scene file
		#`[[[
			vacuum		1
			normal air	1.000277
			cold air	1.000293
			water		1.3330
		]]]
		
		# refractive index 1 - material ray is passing from
		my $ri_1 = $ambient_ri;

		# refractive index 2 - material ray is passing to
		my $ri_2 = $!refraction // $ambient_ri;

		# get index of container if we're leaving one
		my $ri_i = 0;
		my @containers := $int.containers.clone;
		if @containers {
			$ri_i =
				(^@containers)\
					.first({ @containers[$_] === $int.object }) //
				$ri_i
				if $int.exiting;
			
			$ri_1 =
				@containers[$ri_i]\
				.material.transparent.refraction;
		}
		
		# adjust container list for new ray
		if $int.exiting {
			@containers.splice($ri_i, 1);
			($ri_1, $ri_2) = $ri_2, $ri_1;
		} else {
			@containers.unshift($int.object);
		}

		# ratio of refractive indices
		my $ratio = $ri_1 / $ri_2;

		# refracted ray direction
		my $refract_dir;

		if $ratio == 1 { # 1 == no refraction
			$refract_dir = $int.ray.direction;
		} else {
			# angle between boundary surface and incoming ray
			my $cos_theta_1 = $int.direction.dot($int.ray.direction.reverse);
			
			# angle between boundary surface and outgoing ray
			my $cos_theta_2 = 1 - $ratio**2 * (1 - $cos_theta_1**2);
			
			if $cos_theta_2 >= 0 {
				$cos_theta_2 .= sqrt;
				$cos_theta_2 *= -1 if $cos_theta_1 < 0;
				
				$refract_dir = $int.ray.direction.scale($ratio).add(
					$int.direction.scale($ratio*$cos_theta_1 - $cos_theta_2)
				);
			} # else total internal reflection - add internal reflection and scale the color of the reflected and refracted rays using fresnel equations - call to Reflective somehow?
		}

		if $refract_dir {
			my $refract_ray = Pray::Geometry::Ray.new(
				position => $int.position,
				direction => $refract_dir
			);
			
			my $refract_color = $int.scene.ray_color(
				$refract_ray,
				:@containers,
				:$recurse
			);
			
			return $refract_color if $int.exiting;

			return $refract_color.scale($.color_scaled);
		}

		return black;
	}
}
