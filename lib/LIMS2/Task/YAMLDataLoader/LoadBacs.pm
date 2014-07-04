package LIMS2::Task::YAMLDataLoader::LoadBacs;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::YAMLDataLoader::LoadBacs::VERSION = '0.011';
}
## use critic


use strict;
use warnings FATAL => 'all';

use Moose;
use LIMS2::Util::YAMLIterator;
use namespace::autoclean;

extends 'LIMS2::Task::YAMLDataLoader';

override abstract => sub {
    'Load BACs from YAML file';
};

override create => sub {
    my ( $self, $datum ) = @_;

    $self->model->create_bac_clone( $datum );
};

override record_key => sub {
    my ( $self, $datum ) = @_;

    return $datum->{bac_name} || '<undef>';
};

__PACKAGE__->meta->make_immutable;

1;

__END__

    
