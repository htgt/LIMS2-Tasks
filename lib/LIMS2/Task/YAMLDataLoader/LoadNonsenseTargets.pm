package LIMS2::Task::YAMLDataLoader::LoadNonsenseTargets;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::YAMLDataLoader::LoadNonsenseTargets::VERSION = '0.016';
}
## use critic


use strict;
use warnings FATAL => 'all';

use Moose;
use LIMS2::Util::WGE;
use JSON;
use Try::Tiny;
use namespace::autoclean;

extends 'LIMS2::Task::YAMLDataLoader';

=head1 NAME

LIMS2::Task::YAMLDataLoader::LoadNonsenseTargets

=head1 DESCRIPTION

Task for loading nonsense crispr & oligo data.

Each 'experiment' will have 3 things associate with it
* Original crispr
* Nonsense oligo
* Nonsense crispr
The data must be inserted in the above order
The original crispr may or may not exist in LIMS2, if it does not import it from WGE
Insert new design 'with nonsense oligo', link it to original crispr
Insert nonsense crispr, link it to the original crispr

=cut

has species => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => 'Species, currently only Mouse or Human is valid',
    traits        => [ 'Getopt' ],
);

has assembly => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => 'Genome assembly for species',
    traits        => [ 'Getopt' ],
);

has user => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => 'User importing nonsense targets',
    traits        => [ 'Getopt' ],
);

has wge_api => (
    is      => 'ro',
    isa     => 'LIMS2::Util::WGE',
    default => sub{ LIMS2::Util::WGE->new },
    traits        => [ 'NoGetopt' ],
);

override abstract => sub {
    'Load crisprs and oligos for nonsense targets from YAML file';
};

override create => sub {
    my ( $self, $datum ) = @_;

    # The original crispr will have a WGE ID, check if this already exists in LIMS2
    # If it does not then import from WGE to LIMS2
    my $orig_crispr = try{ $self->model->retrieve_crispr( { wge_crispr_id => $datum->{orig_crispr_id} } ) };
    unless ( $orig_crispr ) {
        $self->log->debug( 'Crispr not present in LIMS2, importing WGE crispr into LIMS2 id : '
                . $datum->{orig_crispr_id} );

        my ($crispr_data) = $self->model->import_wge_crisprs(
            [ $datum->{orig_crispr_id} ], $self->species, $self->assembly, $self->wge_api );
        $orig_crispr = $crispr_data->{db_crispr};

        $self->log->info( 'Imported crispr from WGE: ' . $datum->{orig_crispr_id}
                . ' to LIMS2: ' . $orig_crispr->id );
    }

    # import the nonsense design ( one oligo )
    my $nonsense_design_data = $self->extract_nonsense_design_data( $datum, $orig_crispr );
    my $design = $self->model->c_create_design( $nonsense_design_data );
    $self->log->info( 'Created new nonsense design: ' . $design->id );

    # import the nonsense crispr
    my $nonsense_crispr_data = $self->extract_nonsense_crispr_data( $datum, $orig_crispr );
    my $nonsense_crispr = $self->model->create_crispr( $nonsense_crispr_data );
    $self->log->info( 'Created new nonsense crispr ' . $nonsense_crispr->id );
};

override record_key => sub {
    my ( $self, $datum ) = @_;

    return $datum->{gene_id} . '_' . $datum->{orig_crispr_id} || '<undef>';
};

override wanted => sub {
    my ( $self, $datum ) = @_;

    if ( !defined $datum->{orig_crispr_id} ) {
        $self->log->warn( "Skipping .. no original crispr id " );
        return 0;
    }
    elsif ( !defined $datum->{nonsense_crispr_seq} ) {
        $self->log->warn( "Skipping .. no sequence for nonsense crispr" );
        return 0;
    }
    elsif ( !defined $datum->{oligo_seq} ) {
        $self->log->warn( "Skipping .. no sequence for nonsense oligo" );
        return 0;
    }

    return 1;
};

=head2 extract_nonsense_design_data

Create a hash of data for the nonsense design that can be passed
to the c_create_design method in LIMS2.

=cut
sub extract_nonsense_design_data {
    my ( $self, $datum, $orig_crispr ) = @_;

    # if oligo strand is -ve then revcomp so it is on the +ve strand
    # we store all our sequences in LIMS2 on the +ve strand
    my $oligo_seq = $datum->{oligo_strand} == -1 ? revcomp( $datum->{oligo_seq} ) : $datum->{oligo_seq};

    my $oligo_data = {
        type => 'N',
        seq  => $oligo_seq,
        loci => [
            {   chr_name   => $datum->{chromosome},
                chr_start  => $datum->{oligo_start},
                chr_end    => $datum->{oligo_end},
                chr_strand => $datum->{oligo_strand},
                species    => $self->species,
                assembly   => $self->assembly,
            }
        ]
    };
    my $gene_type = $self->calculate_gene_type( $datum->{gene_id} );
    # add comment to design detailing the targeted exon and the stop codon
    # that would be introduced
    my $design_comment = {
        category     => 'Other',
        comment_text => 'Nonsense oligo for exon: ' . $datum->{exon_id}
                        . ' which introduces stop codon: ' . $datum->{stop_codon},
        created_by   => $self->user,
    };

    return {
        species                   => $self->species,
        type                      => 'nonsense',
        created_by                => $self->user,
        target_transcript         => $datum->{canonical_transcript},
        oligos                    => [ $oligo_data ],
        comments                  => [ $design_comment ],
        gene_ids                  => [ { gene_id => $datum->{gene_id} , gene_type_id => $gene_type } ],
        nonsense_design_crispr_id => $orig_crispr->id,
    };
}

=head2 extract_nonsense_crispr_data

Create a hash of data for the nonsense crispr that can be passed
to the create_crispr method in LIMS2.

=cut
sub extract_nonsense_crispr_data {
    my ( $self, $datum, $orig_crispr ) = @_;

    # add a json comment about it being a nonsense crispr
    # along with some other useful information
    my $comment = encode_json {
        gene_id    => $datum->{gene_id},
        exon_id    => $datum->{exon_id},
        stop_codon => $datum->{stop_codon},
        vcf        => $datum->{vcf},
    };
    # locus information for nonsense crispr is identical to
    # that of the original crispr
    my $locus = $orig_crispr->current_locus->as_hash;

    return {
        type                 => $orig_crispr->crispr_loci_type_id,
        seq                  => $datum->{nonsense_crispr_seq},
        species              => $orig_crispr->species_id,
        locus                => $locus,
        pam_right            => $orig_crispr->pam_right,
        off_target_summary   => $datum->{nonsense_off_target_summary},
        off_target_algorithm => 'bwa',
        off_target_outlier   => 0,
        comment              => $comment,
        nonsense_crispr_original_crispr_id => $orig_crispr->id,
    };
}

=head2 calculate_gene_type

Work out type of gene identifier.

=cut
sub calculate_gene_type {
    my ( $self, $gene_id ) = @_;

    my $gene_type = $gene_id =~ /^MGI/  ? 'MGI'
                  : $gene_id =~ /^HGNC/ ? 'HGNC'
                  : $gene_id =~ /^LBL/  ? 'enhancer-region'
                  : $gene_id =~ /^CGI/  ? 'CPG-island'
                  : $gene_id =~ /^mmu/  ? 'miRBase'
                  :                       'marker-symbol'
                  ;

    return $gene_type;
}

=head2 revcomp

Reverse compliment a dna sequence.

=cut
sub revcomp {
    my $seq = shift;
    my $revcomp = reverse( $seq );
    $revcomp =~ tr/ACGTacgt/TGCAtgca/;
    return $revcomp;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
