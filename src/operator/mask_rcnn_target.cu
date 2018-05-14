/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

/*!
 * Copyright (c) 2015 by Contributors
 * Copyright (c) 2018 University of Maryland, College Park
 * Licensed under The Apache-2.0 License [see LICENSE for details]
 * \file mask_rcnn_target.cu
 * \brief MaskRcnnTarget Operator
 * \author Mahyar Najibi, Bharat Singh
*/

#include "./mask_rcnn_target-inl.h"
#include "../coco_api/common/maskApi.h"
#include <set>
#include <math.h>
#include <unistd.h>
#include <dmlc/logging.h>
#include <dmlc/parameter.h>
#include <mxnet/operator.h>
#include <mshadow/tensor.h>
#include <mshadow/cuda/reduce.cuh>
#include <thrust/sort.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include "./operator_common.h"
#include "./mshadow_op.h"
#include <time.h>


namespace mxnet {
namespace op {
namespace mask_utils {
    // Mask Utility Functions
    inline void convertPoly2Mask(const float* roi, const float* poly, const int mask_size, float* mask)
    {
     /* !
     Converts a polygon to a pre-defined mask wrt to an roi
     *****Inputs****
     roi: The RoI bounding box 
     poly: The polygon points the pre-defined format(see below)
     mask_size: The mask size
     *****Outputs****
     overlap: overlap of each box in boxes1 to each box in boxes2
     */
      float w = roi[3] - roi[1];
      float h = roi[4] - roi[2];
      w = std::max((float)1, w);
      h = std::max((float)1, h);
      int n_seg = poly[1];

      int offset = 1 + n_seg;
      RLE* rles;
      rlesInit(&rles, n_seg);
      for(int i = 0; i < n_seg; i++){
        int cur_len = poly[i+1];
        double* xys = new double[cur_len];
        for(int j = 0; j < cur_len; j++){
          if(j % 2 == 0)
            xys[j] = (poly[offset+j] - roi[1]) * mask_size / w;
          else
            xys[j] = (poly[offset+j] - roi[2]) * mask_size / h;
        }
        rleFrPoly(rles + i, xys, cur_len/2, mask_size, mask_size);
        delete [] xys;
        offset += cur_len;
      }
      // Decode RLE to mask
      byte* byte_mask = new byte[mask_size*mask_size*n_seg];
      rleDecode(rles, byte_mask, n_seg);
      // Flatten mask
      for(int j = 0; j < mask_size*mask_size; j++)
      {
        float cur_byte = 0;
        for(int i = 0; i< n_seg; i++){
          int offset = i * mask_size * mask_size + j;
          if(byte_mask[offset]==1){
            cur_byte = 1;
            break;
          }
        }
        mask[j] = cur_byte;
      }
      
      // Check to make sure we don't have memory leak
      rlesFree(&rles, n_seg);
      delete [] byte_mask;

    }
    inline void expandBinaryMasks2ClassMasks(const float* binary_mask, const int category, const int mask_size, float* class_masks)
    {
      /* !
     Given binary masks and the classes, copy each into the correct category channel
     *****Inputs****
     binary_mask: binary masks computed
     category: category for the mask
     mask_size: mask_size
     *****Outputs****
     class_masks: output masks which has param_.num_classes channels
     */
      int offset = category * mask_size * mask_size;
      for(int i = 0; i < mask_size * mask_size; i++){
        class_masks[offset + i] = (binary_mask[i] == 1) ? 1 : 0;
      }
    }

}  // namespace utils


template<typename xpu>
class MaskRcnnTargetGPUOp : public Operator{
 public:
 	float* cmask_outs;
  float* crois, *cmask_boxes, *cgt_masks, *cmask_ids;

  explicit MaskRcnnTargetGPUOp(MaskRcnnTargetParam param) {
    this->param_ = param;
    this->cmask_outs = new float[param_.batch_size*param_.max_output_masks*param_.mask_size*param_.mask_size*param_.num_classes];
    this->crois = new float[param_.batch_size*param_.num_proposals*5];
    this->cmask_boxes = new float[param_.batch_size*param_.max_num_gts*4];
    this->cgt_masks = new float[param_.batch_size*param_.max_num_gts*param_.max_polygon_len];
    this->cmask_ids = new float[param_.batch_size*param_.num_proposals];
  }
  ~MaskRcnnTargetGPUOp() {
    delete [] this->cmask_outs; 
    delete [] this->crois;
    delete [] this->cmask_boxes;
    delete [] this->cgt_masks;
    delete [] this->cmask_ids;
  }

  virtual void Forward(const OpContext &ctx,
                       const std::vector<TBlob> &in_data,
                       const std::vector<OpReqType> &req,
                       const std::vector<TBlob> &out_data,
                       const std::vector<TBlob> &aux_states) {
  	CHECK_EQ(in_data.size(), 4);
    CHECK_EQ(out_data.size(), 1);
    using namespace mshadow;
    using namespace mshadow::expr;
    // The polygon format for each ground-truth object is as follows:
    // [category, num_seg, len_seg1, len_seg2,....,len_segn, seg1_x1,seg1_y1,...,seg1_xm,seg1_ym,seg2_x1,seg2_y1,...]

    // Get input
    Stream<gpu> *s = ctx.get_stream<gpu>();
    Tensor<gpu, 2> rois = in_data[mask::kRoIs].get<gpu, 2, real_t>(s);
    Tensor<gpu, 3> mask_boxes = in_data[mask::kMaskBoxes].get<gpu, 3, real_t>(s);
    Tensor<gpu, 3> gt_masks = in_data[mask::kMaskPolys].get<gpu, 3, real_t>(s);\
    Tensor<gpu, 2> mask_ids = in_data[mask::kMaskIds].get<gpu, 2, real_t>(s);

    // Copy to CPU
    cudaMemcpy(crois, rois.dptr_, param_.batch_size*param_.num_proposals*5*sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(cmask_boxes, mask_boxes.dptr_, param_.batch_size*param_.max_num_gts*4*sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(cgt_masks, gt_masks.dptr_, param_.batch_size*param_.max_num_gts*param_.max_polygon_len*sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(cmask_ids, mask_ids.dptr_, param_.batch_size*param_.num_proposals*sizeof(float), cudaMemcpyDeviceToHost);

    // Initialize the mask memory
    int mask_mem_size = param_.batch_size*param_.max_output_masks*param_.mask_size*param_.mask_size*param_.num_classes;
    for(int i = 0; i < mask_mem_size; i++)
      cmask_outs[i] = param_.ignore_label;

    // Allocate memory for binary mask
    float* binary_mask = new float[param_.mask_size*param_.mask_size];
    for(int i = 0; i < param_.batch_size; i++){
      for(int j = 0; j < param_.num_proposals && j< param_.max_output_masks; j++){
        int offset = i * param_.num_proposals + j;
        int mask_id = cmask_ids[offset];
        int poly_offset = i * param_.max_num_gts * param_.max_polygon_len + mask_id * param_.max_polygon_len; 
        // Convert the mask polygon to a binary mask
        mask_utils::convertPoly2Mask(crois + offset, cgt_masks + poly_offset, param_.mask_size, binary_mask);
        // In our poly encoding the first element is the category
        int category = (int) cgt_masks[poly_offset];
        // Expand the binary mask to a class specific mask
        int out_offset =  (i * param_.max_output_masks + j) * 
                          param_.mask_size * param_.mask_size * param_.num_classes;

        mask_utils::expandBinaryMasks2ClassMasks(binary_mask, category, param_.mask_size, cmask_outs + out_offset);
      }
    }
    delete [] binary_mask;

    // Get output
	  Stream<gpu> *so = ctx.get_stream<gpu>();    
    Tensor<gpu, 4> out_masks = out_data[mask::kMaskTargets].get<gpu, 4, real_t>(so);

    // Copy output to the GPU
    cudaMemcpy(out_masks.dptr_, cmask_outs, \
      param_.batch_size*param_.max_output_masks*param_.mask_size*param_.mask_size*param_.num_classes*sizeof(float), \
      cudaMemcpyHostToDevice);
  }

  virtual void Backward(const OpContext &ctx,
                        const std::vector<TBlob> &out_grad,
                        const std::vector<TBlob> &in_data,
                        const std::vector<TBlob> &out_data,
                        const std::vector<OpReqType> &req,
                        const std::vector<TBlob> &in_grad,
                        const std::vector<TBlob> &aux_states) {
    using namespace mshadow;
    using namespace mshadow::expr;
    CHECK_EQ(in_grad.size(), 3);

    Stream<xpu> *s = ctx.get_stream<xpu>();
    Tensor<xpu, 2> grois = in_grad[mask::kRoIs].get<xpu, 2, real_t>(s);
    Tensor<xpu, 3> gmask_boxes = in_grad[mask::kMaskBoxes].get<xpu, 3, real_t>(s);
    Tensor<xpu, 3> gmask_polys = in_grad[mask::kMaskPolys].get<xpu, 3, real_t>(s);
    Tensor<xpu, 2> gmask_ids = in_grad[mask::kMaskIds].get<xpu, 2, real_t>(s);

    Assign(grois, req[mask::kRoIs], 0);
    Assign(gmask_boxes, req[mask::kMaskBoxes], 0);
    Assign(gmask_polys, req[mask::kMaskPolys], 0);
    Assign(gmask_ids, req[mask::kMaskIds], 0);

  
  }

 private:
  MaskRcnnTargetParam param_;
};  // class MaskRcnnTarget

template<>
Operator *CreateOp<gpu>(MaskRcnnTargetParam param) {
  return new MaskRcnnTargetGPUOp<gpu>(param);
}

}  // namespace op
}  // namespace mxnet