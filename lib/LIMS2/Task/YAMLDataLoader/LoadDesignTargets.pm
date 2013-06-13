package LIMS2::Task::YAMLDataLoader::LoadDesignTargets;

use Moose;
use LIMS2::Util::YAMLIterator;
use namespace::autoclean;

extends 'LIMS2::Task::YAMLDataLoader';

override abstract => sub {
    'Load design targets from YAML file';
};

override create => sub {
    my ( $self, $datum ) = @_;

    $self->model->create_design_target( $datum );
};

override record_key => sub {
    my ( $self, $datum ) = @_;

    return $datum->{ensembl_exon_id} || '<undef>';
};

override wanted => sub {
    my ( $self, $datum ) = @_;

    my $current_target = $self->model->schema->resultset( 'DesignTarget' )->find(
        { ensembl_exon_id => $datum->{ensembl_exon_id} }
    );

    if ( $current_target ) {
        $self->log->warn( 'Target already exists for exon: ' . $datum->{ensembl_exon_id} );
        return 0;
    }

    return 1;
};

__PACKAGE__->meta->make_immutable;

1;

__END__
