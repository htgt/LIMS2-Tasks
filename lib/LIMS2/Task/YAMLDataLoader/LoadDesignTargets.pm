package LIMS2::Task::YAMLDataLoader::LoadDesignTargets;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::YAMLDataLoader::LoadDesignTargets::VERSION = '0.014';
}
## use critic


use Moose;
use LIMS2::Util::YAMLIterator;
use namespace::autoclean;

extends 'LIMS2::Task::YAMLDataLoader';

override abstract => sub {
    'Load design targets from YAML file';
};

override create => sub {
    my ( $self, $datum ) = @_;

    $self->model->c_create_design_target( $datum );
};

override record_key => sub {
    my ( $self, $datum ) = @_;

    my $gene = $datum->{gene_id} ? $datum->{gene_id} : $datum->{marker_symbol};
    return $gene . '-' . $datum->{ensembl_gene_id} || '<undef>';
};

override wanted => sub {
    my ( $self, $datum ) = @_;

    return 1;
};

__PACKAGE__->meta->make_immutable;

1;

__END__
