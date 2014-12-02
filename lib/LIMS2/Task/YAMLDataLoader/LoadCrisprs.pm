package LIMS2::Task::YAMLDataLoader::LoadCrisprs;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::YAMLDataLoader::LoadCrisprs::VERSION = '0.012';
}
## use critic


use strict;
use warnings FATAL => 'all';

use Moose;
use LIMS2::Util::YAMLIterator;
use List::MoreUtils qw( all );
use namespace::autoclean;

extends 'LIMS2::Task::YAMLDataLoader';

has species => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => 'Species these crispr sites target, currently only Mouse or Human is valid',
    traits        => [ 'Getopt' ],
);

has assembly => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => 'Assembly these crispr sites target',
    traits        => [ 'Getopt' ],
);

has build => (
    is            => 'ro',
    isa           => 'Int',
    required      => 1,
    documentation => 'Assembly build the off targets for the crispr hit',
    traits        => [ 'Getopt' ],
);

override abstract => sub {
    'Load crisprs from YAML file';
};

override create => sub {
    my ( $self, $datum ) = @_;

    $datum->{species} = $self->species;
    $datum->{locus}{assembly} = $self->assembly;
    for my $o ( @{ $datum->{off_targets} || [] } ) {
        $o->{assembly} = $self->assembly;
        $o->{build} = $self->build;
    }

    $self->model->create_crispr( $datum );
};

override record_key => sub {
    my ( $self, $datum ) = @_;

    return  'crispr seq: ' . $datum->{seq};
};

override wanted => sub {
    my ( $self, $datum ) = @_;

    unless ( defined $datum->{locus} ) {
        $self->log->warn( "Skipping crispr, no locus" );
        return 0;
    }

    return 1;
};

__PACKAGE__->meta->make_immutable;

1;

__END__
