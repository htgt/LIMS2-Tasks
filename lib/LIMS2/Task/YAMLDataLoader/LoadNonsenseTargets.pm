package LIMS2::Task::YAMLDataLoader::LoadDesigns;

use strict;
use warnings FATAL => 'all';

use Moose;
use LIMS2::Util::WGE;
use LIMS2::Util::YAMLIterator;
use List::MoreUtils qw( all );
use JSON;
use namespace::autoclean;

extends 'LIMS2::Task::YAMLDataLoader';

=pod

New LIMS2-Task for loading nonsense crispr & oligo data
* Each 'experiment' will have 3 things associate with it
    * Original crispr
    * Nonsense oligo
    * Nonsense crispr
* The data must be inserted in the above order
* The original crispr may or may not exist in LIMS2, if it does not import it from WGE
* Insert new design 'with nonsense oligo', link it to original crispr
    * make sure to link design to gene
    * Add a comment on the design to indicate which exon we are targetting
* Insert nonsense crispr, link it to the original crispr

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
);

override abstract => sub {
    'Load crisprs and oligos for nonsense targets from YAML file';
};

override create => sub {
    my ( $self, $datum ) = @_;

    # ORIGINAL CRISPR
    # Will have WGE ID, check if this already exists in LIMS2
    # If it does not then import from WGE to LIMS2
    my $orig_crispr = try{ $self->model->retrieve_crispr( { wge_crispr_id => $datum->{orig_crispr_id} } ) };
    unless ( $orig_crispr ) {
        my ( $crispr_data ) = $self->model->import_wge_crisprs( $ids, $self->species, $self->assembly, $self->wge_api );
        $orig_crispr = $crispr_data->{db_crispr};
    }

    # NONSENSE DESIGN
    # import the nonsense design ( one oligo )
    my $nonsense_design_data = $self->extract_nonsense_design_data( $datum, $orig_crispr );
    $self->model->c_create_design( $nonsense_design_data );

    # NONSENSE CRISPR
    # import the nonsense crispr
    my $nonsense_crispr_data = $self->extract_nonsense_crispr_data( $datum, $orig_crispr );
    $self->model->create_crispr( $nonsense_crispr_data );
};

override record_key => sub {
    my ( $self, $datum ) = @_;

    return $datum->{id} || '<undef>';
};

override wanted => sub {
    my ( $self, $datum ) = @_;

    # check for following things:
    # original crispr
    # nonsense oligo
    # nonsense crispr
    # nonsense crispr is same location as original crispr

    return 1;
};

=head2 extract_nonsense_design_data

desc

=cut
sub extract_nonsense_design_data {
    my ( $self, $datum, $orig_crispr ) = @_;

    # if oligo strand is -ve then revcomp so it is on the +ve strand
    # thats how we store all our sequences in LIMS2
    my $oligo_seq = $datum->{oligo_strand} == -1 ? revcomp( $datum->{oligo_seq} ) : $datum->{oligo_seq};

    my $oligo_data = {
        type => 'N',
        seq  => $oligo_seq,
        loci => {
            chr_name   => $datum->{chromosome},
            chr_start  => $datum->{oligo_start},
            chr_end    => $datum->{oligo_end},
            chr_strand => $datum->{oligo_strand},
            species    => $self->species,
            assembly   => $self->assembly,
        }
    };
    my $gene_type = $self->calculate_gene_type( $datum->{gene_id} );
    my $design_comment = {
        category     => 'Other',
        comment_text => 'Nonsense oligo for exon: ' . $datum->{exon_id}
            . ' which introduces stop codon: ' . $datum->{stop_codon},
        created_by => $self->user,
    };

    return {
        species                   => $self->species,
        type                      => 'nonsense',
        created_by                => $self->user,
        target_transcript         => $datum->{canonical_transcript},
        oligos                    => $oligo_data,
        comments                  => $design_comment,
        gene_ids                  => { gene_id => $datum->{gene_id} , gene_type_id => $gene_type },
        nonsense_design_crispr_id => $orig_crispr->id,
    };
}

=head2 extract_nonsense_crispr_data

desc

=cut
sub extract_nonsense_crispr_data {
    my ( $self, $datum, $orig_crispr ) = @_;

    # comment about it being a nonsense crispr
    my $comment = encode_json {
        gene_id    => $datum->{gene_id},
        exon_id    => $datum->{exon_id},
        stop_codon => $datum->{stop_codon},
        vcf        => $datum->{vcf},
    };
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
