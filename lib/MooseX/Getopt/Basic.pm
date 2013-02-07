package MooseX::Getopt::Basic;
# ABSTRACT: MooseX::Getopt::Basic - role to implement the Getopt::Long functionality

use Moose::Role;

use MooseX::Getopt::OptionTypeMap;
use MooseX::Getopt::Meta::Attribute;
use MooseX::Getopt::Meta::Attribute::NoGetopt;
use MooseX::Getopt::ProcessedArgv;
use Try::Tiny;
use Carp ();

use Getopt::Long 2.37 ();

has ARGV       => (is => 'rw', isa => 'ArrayRef', traits => ['NoGetopt']);
has extra_argv => (is => 'rw', isa => 'ArrayRef', traits => ['NoGetopt']);

sub process_argv {
    my ($class, @params) = @_;

    my $constructor_params = ( @params == 1 ? $params[0] : {@params} );

    my $config_from_file;
    if($class->meta->does_role('MooseX::ConfigFromFile')) {
        local @ARGV = @ARGV;

        # just get the configfile arg now out of @ARGV; the rest of the args
        # will be fetched later
        my $configfile;
        my $opt_parser = Getopt::Long::Parser->new( config => [ qw( no_auto_help pass_through no_auto_version ) ] );
        $opt_parser->getoptions( "configfile=s" => \$configfile );

        my $cfmeta = $class->meta->find_attribute_by_name('configfile');

        # was it passed to the constructor?
        if (!defined $configfile)
        {
            my $key = $cfmeta->init_arg;
            $configfile = $constructor_params->{$key} if defined $key;
        }

        if(!defined $configfile) {
            # this is a classic legacy usecase documented in
            # MooseX::ConfigFromFile that we should continue to support
            $configfile = try { $class->configfile };

            $configfile = $cfmeta->default
                if not defined $configfile and $cfmeta->has_default;
            if (ref $configfile eq 'CODE') {
                # not sure theres a lot you can do with the class and may break some assumptions
                # warn?
                $configfile = &$configfile($class);
            }
            if (defined $configfile) {
                $config_from_file = try {
                    $class->get_config_from_file($configfile);
                }
                catch {
                    die $_ unless /Specified configfile '\Q$configfile\E' does not exist/;
                };
            }
        }
        else {
            $config_from_file = $class->get_config_from_file($configfile);
        }
    }

    Carp::croak("Single parameters to new_with_options() must be a HASH ref")
        unless ref($constructor_params) eq 'HASH';

    my %processed = $class->_parse_argv(
        options => [
            $class->_attrs_to_options( $config_from_file )
        ],
        params => $constructor_params,
    );

    my $params = $config_from_file ? { %$config_from_file, %{$processed{params}} } : $processed{params};

    # did the user request usage information?
    if ( $processed{usage} and $params->{help_flag} ) {
        $class->print_usage_text($processed{usage});
    }

    return MooseX::Getopt::ProcessedArgv->new(
         argv_copy          => $processed{argv_copy},
         extra_argv         => $processed{argv},
         usage              => $processed{usage},
         constructor_params => $constructor_params, # explicit params to ->new
         cli_params         => $params, # params from CLI
    );
}

sub new_with_options {
    my ($class, @params) = @_;

    my $pa = $class->process_argv(@params);

    $class->new(
        ARGV       => $pa->argv_copy,
        extra_argv => $pa->extra_argv,
        ( $pa->usage ? ( usage => $pa->usage ) : () ),
        %{ $pa->constructor_params }, # explicit params to ->new
        %{ $pa->cli_params }, # params from CLI
    );
}

sub _getopt_spec { shift->_traditional_spec(@_); }

sub _parse_argv {
    my ( $class, %params ) = @_;

    local @ARGV = @{ $params{params}{argv} || \@ARGV };

    my ( $opt_spec, $name_to_init_arg ) = $class->_getopt_spec(%params);

    # Get a clean copy of the original @ARGV
    my $argv_copy = [ @ARGV ];

    my @warnings;
    my ( $parsed_options, $usage ) = try {
        local $SIG{__WARN__} = sub { push @warnings, @_ };

        return $class->_getopt_get_options(\%params, $opt_spec);
    }
    catch {
        $class->_getopt_spec_exception(\@warnings, $_);
    };

    $class->_getopt_spec_warnings(@warnings) if @warnings;

    # Get a copy of the Getopt::Long-mangled @ARGV
    my $argv_mangled = [ @ARGV ];

    my %constructor_args = (
        map {
            $name_to_init_arg->{$_} => $parsed_options->{$_}
        } keys %$parsed_options,
    );

    return (
        params    => \%constructor_args,
        argv_copy => $argv_copy,
        argv      => $argv_mangled,
        ( defined($usage) ? ( usage => $usage ) : () ),
    );
}

sub _getopt_get_options {
    my ($class, $params, $opt_spec) = @_;
    my %options;
    Getopt::Long::GetOptions(\%options, @$opt_spec);
    return ( \%options, undef );
}

sub _getopt_spec_warnings { }

sub _getopt_spec_exception {
    my ($self, $warnings, $exception) = @_;
    die @$warnings, $exception;
}

# maintained for backwards compatibility only
sub _getopt_full_usage
{
    my ($self, $usage) = @_;
    print $usage->text;
    exit 0;
}
#(this is already documented in MooseX::Getopt. But FIXME later, via RT#82195)
=for Pod::Coverage
    print_usage_text
=cut
sub print_usage_text { shift->_getopt_full_usage(@_) }

sub _usage_format {
    return "usage: %c %o";
}

sub _traditional_spec {
    my ( $class, %params ) = @_;

    my ( @options, %name_to_init_arg, %options );

    foreach my $opt ( @{ $params{options} } ) {
        push @options, $opt->{opt_string};

        my $identifier = $opt->{name};
        $identifier =~ s/\W/_/g; # Getopt::Long does this to all option names

        $name_to_init_arg{$identifier} = $opt->{init_arg};
    }

    return ( \@options, \%name_to_init_arg );
}

sub _compute_getopt_attrs {
    my $class = shift;
    sort { $a->insertion_order <=> $b->insertion_order }
    grep {
        $_->does("MooseX::Getopt::Meta::Attribute::Trait")
            or
        $_->name !~ /^_/
    } grep {
        !$_->does('MooseX::Getopt::Meta::Attribute::Trait::NoGetopt')
    } $class->meta->get_all_attributes
}

sub _get_cmd_flags_for_attr {
    my ( $class, $attr ) = @_;

    my $flag = $attr->name;

    my @aliases;

    if ($attr->does('MooseX::Getopt::Meta::Attribute::Trait')) {
        $flag = $attr->cmd_flag if $attr->has_cmd_flag;
        @aliases = @{ $attr->cmd_aliases } if $attr->has_cmd_aliases;
    }

    return ( $flag, @aliases );
}

sub _attrs_to_options {
    my $class = shift;
    my $config_from_file = shift || {};

    my @options;

    foreach my $attr ($class->_compute_getopt_attrs) {
        my ( $flag, @aliases ) = $class->_get_cmd_flags_for_attr($attr);

        my $opt_string = join(q{|}, $flag, @aliases);

        if ($attr->name eq 'configfile') {
            $opt_string .= '=s';
        }
        elsif ($attr->has_type_constraint) {
            my $type = $attr->type_constraint;
            if (MooseX::Getopt::OptionTypeMap->has_option_type($type)) {
                $opt_string .= MooseX::Getopt::OptionTypeMap->get_option_type($type)
            }
        }

        push @options, {
            name       => $flag,
            init_arg   => $attr->init_arg,
            opt_string => $opt_string,
            required   => $attr->is_required && !$attr->has_default && !$attr->has_builder && !exists $config_from_file->{$attr->name},
            # NOTE:
            # this "feature" was breaking because
            # Getopt::Long::Descriptive would return
            # the default value as if it was a command
            # line flag, which would then override the
            # one passed into a constructor.
            # See 100_gld_default_bug.t for an example
            # - SL
            #( ( $attr->has_default && ( $attr->is_default_a_coderef xor $attr->is_lazy ) ) ? ( default => $attr->default({}) ) : () ),
            ( $attr->has_documentation ? ( doc => $attr->documentation ) : () ),
        }
    }

    return @options;
}

no Moose::Role;
1;

=head1 SYNOPSIS

  ## In your class
  package My::App;
  use Moose;

  with 'MooseX::Getopt::Basic';

  has 'out' => (is => 'rw', isa => 'Str', required => 1);
  has 'in'  => (is => 'rw', isa => 'Str', required => 1);

  # ... rest of the class here

  ## in your script
  #!/usr/bin/perl

  use My::App;

  my $app = My::App->new_with_options();
  # ... rest of the script here

  ## on the command line
  % perl my_app_script.pl --in file.input --out file.dump

=head1 DESCRIPTION

This is like L<MooseX::Getopt> and can be used instead except that it
doesn't make use of L<Getopt::Long::Descriptive> (or "GLD" for short).

=method new_with_options

See L<MooseX::Getopt/new_with_options>.

=method process_argv

See L<MooseX::Getopt/process_argv>.

=cut
