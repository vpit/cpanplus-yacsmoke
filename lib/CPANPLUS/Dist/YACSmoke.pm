package CPANPLUS::Dist::YACSmoke;

use strict;
use warnings;

use base qw(CPANPLUS::Dist::Base);

use Carp;
use CPANPLUS::Internals::Utils;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Internals::Constants::Report;
use CPANPLUS::Error;
use Params::Check qw[check];
use POSIX qw( O_CREAT O_RDWR );         # for SDBM_File
use version;
use SDBM_File;
use File::Spec::Functions;
use Regexp::Assemble;
use Config::IniFiles;

use vars qw($VERSION);

$VERSION = '0.33_02';

use constant DATABASE_FILE => 'cpansmoke.dat';
use constant CONFIG_FILE   => 'cpansmoke.ini';

{ 

$ENV{AUTOMATED_TESTING} = 1;
$ENV{PERL_MM_USE_DEFAULT} = 1; # despite verbose setting

my %Checked;
my $TiedObj;
my $exclude_dists;
my %throw_away;

  sub _is_excluded_dist {
    return unless $exclude_dists;
    my $dist = shift || return;
    return 1 if $dist =~ $exclude_dists->re();
  }

  sub init {
    my $self = shift;
    my $mod  = $self->parent;
    my $cb   = $mod->parent;

    $self->status->mk_accessors(qw(_prepare _create _prereqs _skipbuild));

    my $conf = $cb->configure_object;

    if ( $conf->get_conf( 'prefer_makefile' ) ) {
        msg(qq{CPANPLUS is prefering Makefile.PL});
    }
    else {
        msg(qq{CPANPLUS is prefering Build.PL});
    }

    return 1 if $TiedObj;

    my $filename = catfile( CPANPLUS::Internals::Utils->_home_dir(), '.cpanplus', DATABASE_FILE );
    msg(qq{Loading YACSmoke database "$filename"});
    $TiedObj = tie( %Checked, 'SDBM_File', $filename, O_CREAT|O_RDWR, 0644 )
	or error(qq{Failed to open "$filename": $!});

    my $config_file = catfile( CPANPLUS::Internals::Utils->_home_dir(), '.cpanplus', CONFIG_FILE );
    if ( -r $config_file ) {
       my $cfg = Config::IniFiles->new(-file => $config_file);
       my @list = $cfg->val( 'CONFIG', 'exclude_dists' );
       if ( @list ) {
          $exclude_dists = Regexp::Assemble->new();
          $exclude_dists->add( @list );
       }
    }

    # munge test report
    $cb->_register_callback(
        name => 'munge_test_report',
        code => sub {
		  my $mod    = shift;
		  my $report = shift || "";
		  my $grade  = shift;
		  my $safe_ver = version->new('0.85_04');
		  SWITCH: {
		    if ( $grade ne GRADE_PASS and $report =~ /Will not install prerequisite /s ) {
			$throw_away{ $mod->package_name . '-' . $mod->package_version } = 'toss';
			last SWITCH;
		    }
		    my $int_ver = $CPANPLUS::Internals::VERSION;
		    last SWITCH if version->new($int_ver) >= $safe_ver;
		    if ( $grade eq GRADE_NA ) {
		        my $author  = $mod->author->author;
		        my $buffer  = CPANPLUS::Error->stack_as_string;
		        my $stage   = TEST_FAIL_STAGE->($buffer);
		        $report    .= REPORT_MESSAGE_HEADER->( $int_ver, $author );
		        $report    .= REPORT_MESSAGE_FAIL_HEADER->( $stage, $buffer );
		    }
		    if ( $grade ne GRADE_PASS and $report =~ /No \'Makefile.PL\' found - attempting to generate one/s ) {
			$throw_away{ $mod->package_name . '-' . $mod->package_version } = 'toss';
		    }
		  }
		  $report =~ s/\[MSG\].*may need to build a \'CPANPLUS::Dist::YACSmoke\' package for it as well.*?\n//sg;
		  $report .=
			"\nThis report was machine-generated by CPANPLUS::Dist::YACSmoke $VERSION.\n";
		  if ( $ENV{PERL5_MINIYACSMOKER} ) {
			$report .= "Powered by miniyacsmoker version " . $ENV{PERL5_MINIYACSMOKER} . "\n";
		  }
		  if ( $ENV{PERL5_MINISMOKEBOX} ) {
			$report .= "Powered by minismokebox version " . $ENV{PERL5_MINISMOKEBOX} . "\n";
		  }
		  $report .= _gen_report();
		  return $report;
        },
    );

    $cb->_register_callback(
      name => 'install_prerequisite',
      code => sub {
		my $mod   = shift;
		my $root = $mod->package_name .'-'. $mod->package_version;

		unless ($TiedObj) {
		  croak "Not connected to database!";
		}

		while (my $arg = shift) {
		  my $package = $arg->package_name .'-'. $arg->package_version;

		  # BUG: Exclusion does not seem to work for prereqs.
		  # Sometimes it seems that the install_prerequisite
		  # callback is not even called! Need to investigate.

		  if ( _is_excluded_dist($package) ) { # prereq on excluded list
			msg("Prereq $package is excluded");
			return;
		  }

		  my $checked = $Checked{$package};
		  if (defined $checked &&
			  #$checked =~ /aborted|fail|na/ ) {
			  $checked =~ /fail|na/ ) {

			  msg("Known uninstallable prereqs $package - aborting install\n");
			  $Checked{$root} = "aborted";
			  return;
		  }
		}
		return 1;
      },
    );

    $cb->_register_callback(
      name => 'send_test_report',
      code => sub {

		unless ($TiedObj) {
		  exit error("Not connected to database!");
		}
		my $mod   = shift;
		my $grade = lc shift;
		my $package = $mod->package_name .'-'. $mod->package_version;
		my $checked = $Checked{$package};
		
		# Did we want to throw away this report?
		my $throw = delete $throw_away{ $package };
		return if $throw;

          # Simplified algorithm for reporting: 
          # * don't send a report if
          #   - we get the same results as the last report sent
          #   - it passed the last test but not now
          #   - it didn't pass the last test or now

		return if (defined $checked && (
                    ($checked eq $grade)                     ||
		    ($checked ne 'pass' && $grade ne 'pass')));

		  $Checked{$package} = $grade;

		return 1;
      },
    );

    $cb->_register_callback(
      name => 'edit_test_report',
      code => sub { return; },
    );


    return 1;
  }

  sub create {
    my $self = shift;
    my $mod  = $self->parent;
    my $dist_cpan = $mod->status->dist_cpan;

    if ( $dist_cpan->status->created ) {
       my %hash = @_;
       my $conf = $mod->parent->configure_object;
       my $args;
       my($force,$verbose,$prereq_target,$prereq_format, $prereq_build);
       {   local $Params::Check::ALLOW_UNKNOWN = 1;
          my $tmpl = {
            force           => {    default => $conf->get_conf('force'),
                                    store   => \$force },
            verbose         => {    default => $conf->get_conf('verbose'),
                                    store   => \$verbose },
            prereq_target   => {    default => '', store => \$prereq_target },
            prereq_format   => {    #default => $self->status->installer_type,
                                    default => '',
                                    store   => \$prereq_format },
            prereq_build    => {    default => 0, store => \$prereq_build },                                    
          };
          $args = check( $tmpl, \%hash ) or return;
       }
       return 0 unless 
	  $self->_resolve_prereqs(
                        force           => $force,
                        format          => $prereq_format,
                        verbose         => $verbose,
                        prereqs         => $mod->status->prereqs,
                        target          => $prereq_target,
                        prereq_build    => $prereq_build,
                    );
       $mod->add_to_includepath();
       return 1;
    }

    my $package = $mod->package_name .'-'. $mod->package_version;
    msg(qq{Checking for previous PASS result for "$package"});
    my $checked = $Checked{$package};
    if ( $checked and $checked eq 'pass' ) {
       msg(qq{Found previous PASS result for "$package" skipping tests.});
       push @_, skiptest => 1;
    } 
    $self->SUPER::create( @_ );
  }

sub _env_report {
  my @env_vars= qw(
    /PERL/
    /LC_/
    LANG
    LANGUAGE
    PATH
    SHELL
    COMSPEC
    TERM
    AUTOMATED_TESTING
    AUTHOR_TESTING
    INCLUDE
    LIB
    LD_LIBRARY_PATH
    PROCESSOR_IDENTIFIER
    NUMBER_OF_PROCESSORS
  );
    my @vars_found;
    for my $var ( @env_vars ) {
        if ( $var =~ m{^/(.+)/$} ) {
            push @vars_found, grep { /$1/ } keys %ENV;
        }
        else {
            push @vars_found, $var if exists $ENV{$var};
        }
    }

    my $report = "";
    for my $var ( sort @vars_found ) {
        $report .= "    $var = $ENV{$var}\n" if defined $ENV{$var};
    }
    return $report;
}

sub _special_vars_report {
    my $special_vars = << "HERE";
    Perl: \$^X = $^X
    UID:  \$<  = $<
    EUID: \$>  = $>
    GID:  \$(  = $(
    EGID: \$)  = $)
HERE
    if ( $^O eq 'MSWin32' && eval "require Win32" ) {
        my @getosversion = Win32::GetOSVersion();
        my $getosversion = join(", ", @getosversion);
        $special_vars .= "    Win32::GetOSName = " . Win32::GetOSName() . "\n";
        $special_vars .= "    Win32::GetOSVersion = $getosversion\n";
        $special_vars .= "    Win32::IsAdminUser = " . Win32::IsAdminUser() . "\n";
    }
    return $special_vars;
}

sub _gen_report {
  my $env_vars = _env_report;
  my $special_vars = _special_vars_report();
  my $return = << "ADDREPORT";

------------------------------
ENVIRONMENT AND OTHER CONTEXT
------------------------------

Environment variables:

$env_vars
Perl special variables (and OS-specific diagnostics, for MSWin32):

$special_vars

-------------------------------

ADDREPORT

  return $return;
}

}

1;
__END__

=head1 NAME

CPANPLUS::Dist::YACSmoke - CPANPLUS distribution class that integrates CPAN Testing services into CPANPLUS

=head1 SYNOPSIS

  # CPANPLUS shell - use CPANPLUS::Dist::YACSmoke services during manual use.

  cpanp> s conf dist_type CPANPLUS::Dist::YACSmoke

  cpanp> s save

=head1 DESCRIPTION

CPANPLUS::Dist::YACSmoke is a L<CPANPLUS> distribution class that integrates a number of CPAN Testing services 
into L<CPANPLUS>. 

It will create a database file in the F<.cpanplus> directory, which it
uses to track tested distributions.  This information will be used to
keep from posting multiple reports for the same module, and to keep
from testing modules that use non-passing modules as prerequisites.

If C<prereqs> have been tested previously and have resulted in a C<pass> grade then the tests for those
C<prereqs> will be skipped, speeding up smoke testing.

By default it uses L<CPANPLUS> configuration settings.

It can be utilised during manual use of L<CPANPLUS> by setting the C<dist_type> configuration variable.

Its main utility is in conjunction with L<CPANPLUS::YACSmoke>.

=head1 CONFIGURATION FILE

CPANPLUS::Dist::YACSmoke only honours the C<exclude_dists> in L<CPAN::YACSmoke> style C<ini> files.

The C<exclude_dists> setting, which is laid out as:

  [CONFIG]
  exclude_dists=<<HERE
  mod_perl
  HERE

The above would then ignore any distribution that include the string
'mod_perl' in its name. This is useful for distributions which use
external C libraries, which are not installed, or for which testing
is problematic.

See L<Config::IniFiles> for more information on the INI file format.

=head1 METHODS OVERIDDEN

CPANPLUS::Dist::YACSmoke overrides a number of methods provided by L<CPANPLUS::Dist::Base>

=over

=item C<init>

This method is called just after the new dist object is set up. It initialises the database file if it hasn't been initialised already
and loads the list of excluded distributions from the C<ini> file if that hasn't been loaded already. It also registers callbacks with 
the L<CPANPLUS> backend.

=item C<prepare>

This runs the preparation step of your distribution. This step is meant to set up the environment so the create step can create the actual distribution(file).
This can mean running either C<Makefile.PL> or C<Build.PL>.

CPANPLUS::Dist::YACSmoke will check for the existence of a C<.yacsmoke.yml> in the extracted build directory. If it exists it will
load the meta data that it contains and sets C<$dist-E<gt>status-E<gt>_skipbuild> to true.

=item C<create>

This runs the creation step of your distribution, by running C<make> and C<make test> for instance. The distribution is checked against
the database to see if a C<pass> grade has already been reported for this distribution, if so then C<skiptest> is set and the testsuite 
will not be run.

If C<$dist-E<gt>status-E<gt>_skipbuild> is set to true, CPANPLUS::Dist::YACSmoke will skip the build and test stages completely and resolve
any prereqs for the distribution before adding the build directories C<blib> structure to the include path.

=back

=head1 AUTHOR

Chris C<BinGOs> Williams <chris@bingosnet.co.uk>

Based on L<CPAN::YACSmoke> by Robert Rothenberg and Barbie.

Contributions and patience from Jos Boumans the L<CPANPLUS> guy!

=head1 LICENSE

Copyright C<(c)> Chris Williams, Jos Boumans, Robert Rothenberg and Barbie.

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for
details.

=head1 SEE ALSO

L<CPANPLUS>

L<CPANPLUS::YACSmoke>

L<CPAN::YACSmoke>

