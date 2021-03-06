/* Copyright (C) 2011 Ion Torrent Systems, Inc. All Rights Reserved */
#ifndef REGIONANALYSIS_H
#define REGIONANALYSIS_H

#include "Mask.h"
#include "Separator.h"
#include "IonErr.h"
#include "DPTreephaser.h"
#include "CommandLineOpts.h"
#include "RegionWellsReader.h"

// RegionAnalysis
//
// Provides a parallel processing structure where one thread processes one region at a time.
// Currently treephaser-based phase parameter estimation is implemented here.
// May be easy to extend to other analysis code here.

class RawWells;
class RegionAnalysis {
public:
  RegionAnalysis();

  void analyze(vector<float> *_cf, vector<float> *_ie, vector<float> *_dr, RawWells *_wells, Mask *_mask,
      SequenceItem *_libraryInfo, CommandLineOpts *_clo, const string& _flowOrder, int _numFlows, int numWorkers);

private:
  friend void * RegionAnalysisWorker(void *);
  void worker_Treephaser();
  void worker_AdaptiveTreephaser();

  void NelderMeadOptimization(std::vector<BasecallerRead> &dataAll, DPTreephaser& treephaser, float *parameters, int numEvaluations, int numParameters);
  float evaluateParameters(std::vector<BasecallerRead> &dataAll, DPTreephaser& treephaser, float *parameters);

  CommandLineOpts *   clo;
  RegionWellsReader   wellsReader;
  Mask *              mask;
  SequenceItem *      libraryInfo;
  string              flowOrder;
  int                 numFlows;

  vector<float> *     cf;
  vector<float> *     ie;
  vector<float> *     dr;

  pthread_mutex_t *   common_output_mutex;
};

void *RegionAnalysisWorker(void *);

#endif // REGIONANALYSIS_H
