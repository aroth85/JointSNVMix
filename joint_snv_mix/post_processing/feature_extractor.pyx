'''
Created on 2012-01-26

@author: Andrew Roth
'''
cdef class FeatureExtractor(object):
    def __init__(self, BamFile normal_bam, BamFile tumour_bam):        
        self._normal_bam = normal_bam
        self._tumour_bam = tumour_bam
        
        priors = BinomialPriors()
        params = BinomialParameters()
        
        self._model = SnvMixTwoModel(priors, params)
    
    def get_features(self, JointBinaryCounterRow row):
        normal_features = self._get_genome_features(row, self._normal_bam)
        tumour_features = self._get_genome_features(row, self._tumour_bam)
        
        jsm_features = self._get_joint_snv_mix_features(row)
        
        return normal_features + tumour_features + jsm_features
    
    cdef list _get_genome_features(self, JointBinaryCounterRow row, BamFile bam_file):
        cdef PileupIterator pileup_iter
    
        pileup_iter = bam_file.get_pileup_iterator(row._ref, start=row._pos, stop=row._pos + 1)
        
        while True:
            pileup_iter.advance_position()
            
            if pileup_iter._pos == row._pos:
                break
        
        pileup_column = pileup_iter.get_extended_pileup_column()
        
        features = self._parse_column(row, pileup_column)
        
        return features 
    
    cdef list _parse_column(self, JointBinaryCounterRow row, ExtendedPileupColumn pileup_column):
        site_features = self._get_site_features(pileup_column)
        
        ref_base = row._ref_base
        var_base = row._var_base
        
        ref_base_features = self._get_base_features(ref_base, pileup_column)
        var_base_features = self._get_base_features(var_base, pileup_column)        
        
        return site_features + ref_base_features + var_base_features
    
    cdef list _get_joint_snv_mix_features(self, JointBinaryCounterRow row):
        snv_mix_probs = self._model.predict(row._data)
        
        somatic_prob_max = max(snv_mix_probs[1:3])
        non_somatic_prob_max = max(snv_mix_probs[0], max(snv_mix_probs[3:]))
        
        somatic_prob_sum = sum(snv_mix_probs[1:3])
        non_somatic_prob_sum = snv_mix_probs[0] + sum(snv_mix_probs[3:])
        
        wt_prob = snv_mix_probs[0]
        germline_prob = snv_mix_probs[4] + snv_mix_probs[8]
        loh_prob = snv_mix_probs[3] + snv_mix_probs[5]
        err_prob = snv_mix_probs[6] + snv_mix_probs[7]
        
        return snv_mix_probs + [somatic_prob_max,
                                non_somatic_prob_max,
                                somatic_prob_sum,
                                non_somatic_prob_sum,
                                wt_prob,
                                germline_prob,
                                loh_prob,
                                err_prob]
        
    #===================================================================================================================
    # Site specific features
    #===================================================================================================================
    cdef list _get_site_features(self, ExtendedPileupColumn pileup_column):
        depth = pileup_column._depth
        
        # Map qual features
        map_quals_rms = self._get_map_qual_rms(pileup_column)        
        map_quals_zeros = self._get_num_zero_map_qual_reads(pileup_column)
        
        # Alelle count
        alle_count_low_qual = self._get_total_allele_count(pileup_column, 0, 0)
        alle_count_high_qual = self._get_total_allele_count(pileup_column, 30, 30)
    
        return [
                depth,
                map_quals_rms,
                map_quals_zeros,
                alle_count_low_qual,
                alle_count_high_qual
                ]
        
    cdef double _get_map_qual_rms(self, ExtendedPileupColumn pileup_column):
        cdef int i
        cdef double map_qual_rms
        
        map_qual_rms = 0
    
        for i in range(pileup_column._depth):
            map_qual_rms += pow(pileup_column._map_quals[i], 2)
        
        return sqrt(map_qual_rms)
    
    cdef int _get_num_zero_map_qual_reads(self, ExtendedPileupColumn pileup_column):
        cdef int i, map_quals_zeros
        
        map_quals_zeros = 0
    
        for i in range(pileup_column._depth):
            if pileup_column._map_quals[i] == 0:
                map_quals_zeros += 1
        
        return map_quals_zeros
    
    cdef int _get_total_allele_count(self, ExtendedPileupColumn pileup_column, int base_qual, int map_qual):
        cdef char base[2], nucleotides[4]
        cdef int allele_count, i
        
        nucleotides[0] = 'A'
        nucleotides[1] = 'C'
        nucleotides[2] = 'G'
        nucleotides[3] = 'T'
        
        allele_count = 0
        
        for i in range(4):
            base[0] = nucleotides[i]
            base[1] = < char > NULL
            if pileup_column.get_nucleotide_count(base, base_qual, map_qual) > 0:
                allele_count += 1
        
        return allele_count
    
    #===================================================================================================================
    # Base specific features
    #===================================================================================================================
    cdef list _get_base_features(self, char * base, ExtendedPileupColumn pileup_column):
        # Allelic depth features
        base_count_low_quality = pileup_column.get_nucleotide_count(base, 0, 0)        
        base_count_high_quality = pileup_column.get_nucleotide_count(base, 30, 30)
    
        # Base quality features
        base_quals_sum = self._get_base_quals_sum(base, pileup_column, 1)                
        base_quals_square_sum = self._get_base_quals_sum(base, pileup_column, 2)
        
        # Mapping quality features
        map_quals_sum = self._get_map_quals_sum(base, pileup_column, 1)        
        map_quals_square_sum = self._get_map_quals_sum(base, pileup_column, 2)
        
        # Strand features
        forward_strand_count = self._get_forward_strand_count(base, pileup_column, 13)                        
        reverse_strand_count = pileup_column.get_nucleotide_count(base, 13, 0) - forward_strand_count 
        
        # Tail distrance features
        tail_distance_sum = self._get_tail_distance_sum(base, pileup_column, 1)        
        tail_distance_square_sum = self._get_tail_distance_sum(base, pileup_column, 2)
                
        return [
                base_count_low_quality,
                base_count_high_quality,
                base_quals_sum,
                base_quals_square_sum,
                map_quals_sum,
                map_quals_square_sum,
                forward_strand_count,
                reverse_strand_count,
                tail_distance_sum,
                tail_distance_square_sum
                ]
        
    cdef double _get_base_quals_sum(self, char * base, ExtendedPileupColumn pileup_column, double exponent):
        cdef int i
        cdef double base_qual_sum
        
        base_qual_sum = 0
    
        for i in range(pileup_column._depth):
            if base[0] == pileup_column._bases[i]:
                base_qual_sum += pow(pileup_column._base_quals[i], exponent)
        
        return base_qual_sum

    cdef double _get_map_quals_sum(self, char * base, ExtendedPileupColumn pileup_column, double exponent):
        cdef int i
        cdef double map_qual_sum
        
        map_qual_sum = 0
    
        for i in range(pileup_column._depth):
            if base[0] == pileup_column._bases[i]:
                map_qual_sum += pow(pileup_column._map_quals[i], exponent)
        
        return map_qual_sum
    
    cdef int _get_forward_strand_count(self, char * base, ExtendedPileupColumn pileup_column, int min_base_qual):
        cdef int i, forward_strand_count
        
        forward_strand_count = 0
        
        for i in range(pileup_column._depth):
            if (base[0] == pileup_column._bases[i]) and (pileup_column._base_quals[i] >= min_base_qual):
                if pileup_column._is_forward_strand[i]:
                    forward_strand_count += 1
        
        return forward_strand_count
    
    cdef double _get_tail_distance_sum(self, char * base, ExtendedPileupColumn pileup_column, double exponent):
        cdef int i
        cdef double tail_distance_sum
        
        tail_distance_sum = 0
        
        for i in range(pileup_column._depth):
            if base[0] == pileup_column._bases[i]:
                tail_distance_sum += pow(pileup_column._tail_distance[i], exponent)
        
        return tail_distance_sum
                 
    
            
        
    
