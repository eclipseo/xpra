# This file is part of Xpra.
# Copyright (C) 2021-2022 Antoine Martin <antoine@xpra.org>
# Xpra is released under the terms of the GNU GPL v2, or, at your option, any
# later version. See the file COPYING for details.

from time import monotonic
from math import ceil
import numpy

from libc.stdint cimport uintptr_t
from xpra.buffers.membuf cimport getbuf, MemBuf #pylint: disable=syntax-error

from pycuda import driver

from xpra.codecs.codec_debug import may_save_image
from xpra.codecs.cuda_common.cuda_context import get_CUDA_function
from xpra.net.compression import Compressed
from xpra.util import typedict

from xpra.log import Logger
log = Logger("encoder", "nvjpeg")


DEF NVJPEG_MAX_COMPONENT = 4

cdef extern from "cuda_runtime_api.h":
    ctypedef int cudaError_t
    ctypedef void* cudaStream_t
    cudaError_t cudaStreamCreate(cudaStream_t* pStream)
    cudaError_t cudaStreamSynchronize(cudaStream_t stream)

cdef extern from "library_types.h":
    cdef enum libraryPropertyType_t:
        MAJOR_VERSION
        MINOR_VERSION
        PATCH_LEVEL

cdef extern from "nvjpeg.h":
    int NVJPEG_MAX_COMPONENT

    int NVJPEG_VER_MAJOR    #ie: 11
    int NVJPEG_VER_MINOR    #ie: 3
    int NVJPEG_VER_PATCH    #ie: 1
    int NVJPEG_VER_BUILD    #ie: 68

    ctypedef void* NV_ENC_INPUT_PTR
    ctypedef void* NV_ENC_OUTPUT_PTR
    ctypedef void* NV_ENC_REGISTERED_PTR

    ctypedef enum nvjpegStatus_t:
        NVJPEG_STATUS_SUCCESS
        NVJPEG_STATUS_NOT_INITIALIZED
        NVJPEG_STATUS_INVALID_PARAMETER
        NVJPEG_STATUS_BAD_JPEG
        NVJPEG_STATUS_JPEG_NOT_SUPPORTED
        NVJPEG_STATUS_ALLOCATOR_FAILURE
        NVJPEG_STATUS_EXECUTION_FAILED
        NVJPEG_STATUS_ARCH_MISMATCH
        NVJPEG_STATUS_INTERNAL_ERROR
        NVJPEG_STATUS_IMPLEMENTATION_NOT_SUPPORTED

    ctypedef enum nvjpegChromaSubsampling_t:
        NVJPEG_CSS_444
        NVJPEG_CSS_422
        NVJPEG_CSS_420
        NVJPEG_CSS_440
        NVJPEG_CSS_411
        NVJPEG_CSS_410
        NVJPEG_CSS_GRAY
        NVJPEG_CSS_UNKNOWN

    ctypedef enum nvjpegOutputFormat_t:
        NVJPEG_OUTPUT_UNCHANGED
        # return planar luma and chroma, assuming YCbCr colorspace
        NVJPEG_OUTPUT_YUV
        # return luma component only, if YCbCr colorspace
        # or try to convert to grayscale,
        # writes to 1-st channel of nvjpegImage_t
        NVJPEG_OUTPUT_Y
        # convert to planar RGB
        NVJPEG_OUTPUT_RGB
        # convert to planar BGR
        NVJPEG_OUTPUT_BGR
        # convert to interleaved RGB and write to 1-st channel of nvjpegImage_t
        NVJPEG_OUTPUT_RGBI
        # convert to interleaved BGR and write to 1-st channel of nvjpegImage_t
        NVJPEG_OUTPUT_BGRI
        # maximum allowed value
        NVJPEG_OUTPUT_FORMAT_MAX

    ctypedef enum nvjpegInputFormat_t:
        NVJPEG_INPUT_RGB    # Input is RGB - will be converted to YCbCr before encoding
        NVJPEG_INPUT_BGR    # Input is RGB - will be converted to YCbCr before encoding
        NVJPEG_INPUT_RGBI   # Input is interleaved RGB - will be converted to YCbCr before encoding
        NVJPEG_INPUT_BGRI   # Input is interleaved RGB - will be converted to YCbCr before encoding

    ctypedef enum nvjpegBackend_t:
        NVJPEG_BACKEND_DEFAULT
        NVJPEG_BACKEND_HYBRID       # uses CPU for Huffman decode
        NVJPEG_BACKEND_GPU_HYBRID   # uses GPU assisted Huffman decode. nvjpegDecodeBatched will use GPU decoding for baseline JPEG bitstreams with
                                    # interleaved scan when batch size is bigger than 100
        NVJPEG_BACKEND_HARDWARE     # supports baseline JPEG bitstream with single scan. 410 and 411 sub-samplings are not supported

    ctypedef enum nvjpegJpegEncoding_t:
        NVJPEG_ENCODING_UNKNOWN
        NVJPEG_ENCODING_BASELINE_DCT
        NVJPEG_ENCODING_EXTENDED_SEQUENTIAL_DCT_HUFFMAN
        NVJPEG_ENCODING_PROGRESSIVE_DCT_HUFFMAN


    ctypedef struct nvjpegImage_t:
        unsigned char * channel[NVJPEG_MAX_COMPONENT]
        size_t    pitch[NVJPEG_MAX_COMPONENT]

    ctypedef int (*tDevMalloc)(void**, size_t)
    ctypedef int (*tDevFree)(void*)

    ctypedef int (*tPinnedMalloc)(void**, size_t, unsigned int flags)
    ctypedef int (*tPinnedFree)(void*)

    ctypedef struct nvjpegDevAllocator_t:
        tDevMalloc dev_malloc;
        tDevFree dev_free;

    ctypedef struct nvjpegPinnedAllocator_t:
        tPinnedMalloc pinned_malloc
        tPinnedFree pinned_free

    ctypedef struct nvjpegHandle:
        pass
    ctypedef nvjpegHandle* nvjpegHandle_t

    nvjpegStatus_t nvjpegGetProperty(libraryPropertyType_t type, int *value)
    nvjpegStatus_t nvjpegGetCudartProperty(libraryPropertyType_t type, int *value)
    nvjpegStatus_t nvjpegCreate(nvjpegBackend_t backend, nvjpegDevAllocator_t *dev_allocator, nvjpegHandle_t *handle)
    nvjpegStatus_t nvjpegCreateSimple(nvjpegHandle_t *handle)
    nvjpegStatus_t nvjpegCreateEx(nvjpegBackend_t backend,
        nvjpegDevAllocator_t *dev_allocator,
        nvjpegPinnedAllocator_t *pinned_allocator,
        unsigned int flags,
        nvjpegHandle_t *handle)

    nvjpegStatus_t nvjpegDestroy(nvjpegHandle_t handle)
    nvjpegStatus_t nvjpegSetDeviceMemoryPadding(size_t padding, nvjpegHandle_t handle)
    nvjpegStatus_t nvjpegGetDeviceMemoryPadding(size_t *padding, nvjpegHandle_t handle)
    nvjpegStatus_t nvjpegSetPinnedMemoryPadding(size_t padding, nvjpegHandle_t handle)
    nvjpegStatus_t nvjpegGetPinnedMemoryPadding(size_t *padding, nvjpegHandle_t handle)

    nvjpegStatus_t nvjpegGetImageInfo(
        nvjpegHandle_t handle,
        const unsigned char *data,
        size_t length,
        int *nComponents,
        nvjpegChromaSubsampling_t *subsampling,
        int *widths,
        int *heights)

    #Encode:
    ctypedef struct nvjpegEncoderState:
        pass
    ctypedef nvjpegEncoderState* nvjpegEncoderState_t

    nvjpegStatus_t nvjpegEncoderStateCreate(
        nvjpegHandle_t handle,
        nvjpegEncoderState_t *encoder_state,
        cudaStream_t stream);
    nvjpegStatus_t nvjpegEncoderStateDestroy(nvjpegEncoderState_t encoder_state)
    ctypedef struct nvjpegEncoderParams:
        pass
    ctypedef nvjpegEncoderParams* nvjpegEncoderParams_t
    nvjpegStatus_t nvjpegEncoderParamsCreate(
        nvjpegHandle_t handle,
        nvjpegEncoderParams_t *encoder_params,
        cudaStream_t stream)
    nvjpegStatus_t nvjpegEncoderParamsDestroy(nvjpegEncoderParams_t encoder_params)
    nvjpegStatus_t nvjpegEncoderParamsSetQuality(
        nvjpegEncoderParams_t encoder_params,
        const int quality,
        cudaStream_t stream)
    nvjpegStatus_t nvjpegEncoderParamsSetEncoding(
        nvjpegEncoderParams_t encoder_params,
        nvjpegJpegEncoding_t etype,
        cudaStream_t stream)
    nvjpegStatus_t nvjpegEncoderParamsSetOptimizedHuffman(
        nvjpegEncoderParams_t encoder_params,
        const int optimized,
        cudaStream_t stream)
    nvjpegStatus_t nvjpegEncoderParamsSetSamplingFactors(
        nvjpegEncoderParams_t encoder_params,
        const nvjpegChromaSubsampling_t chroma_subsampling,
        cudaStream_t stream)
    nvjpegStatus_t nvjpegEncodeGetBufferSize(
        nvjpegHandle_t handle,
        const nvjpegEncoderParams_t encoder_params,
        int image_width,
        int image_height,
        size_t *max_stream_length)
    nvjpegStatus_t nvjpegEncodeYUV(
            nvjpegHandle_t handle,
            nvjpegEncoderState_t encoder_state,
            const nvjpegEncoderParams_t encoder_params,
            const nvjpegImage_t *source,
            nvjpegChromaSubsampling_t chroma_subsampling,
            int image_width,
            int image_height,
            cudaStream_t stream) nogil
    nvjpegStatus_t nvjpegEncodeImage(
            nvjpegHandle_t handle,
            nvjpegEncoderState_t encoder_state,
            const nvjpegEncoderParams_t encoder_params,
            const nvjpegImage_t *source,
            nvjpegInputFormat_t input_format,
            int image_width,
            int image_height,
            cudaStream_t stream) nogil
    nvjpegStatus_t nvjpegEncodeRetrieveBitstreamDevice(
            nvjpegHandle_t handle,
            nvjpegEncoderState_t encoder_state,
            unsigned char *data,
            size_t *length,
            cudaStream_t stream) nogil
    nvjpegStatus_t nvjpegEncodeRetrieveBitstream(
            nvjpegHandle_t handle,
            nvjpegEncoderState_t encoder_state,
            unsigned char *data,
            size_t *length,
            cudaStream_t stream) nogil

ERR_STRS = {
    NVJPEG_STATUS_SUCCESS                       : "SUCCESS",
    NVJPEG_STATUS_NOT_INITIALIZED               : "NOT_INITIALIZED",
    NVJPEG_STATUS_INVALID_PARAMETER             : "INVALID_PARAMETER",
    NVJPEG_STATUS_BAD_JPEG                      : "BAD_JPEG",
    NVJPEG_STATUS_JPEG_NOT_SUPPORTED            : "JPEG_NOT_SUPPORTED",
    NVJPEG_STATUS_ALLOCATOR_FAILURE             : "ALLOCATOR_FAILURE",
    NVJPEG_STATUS_EXECUTION_FAILED              : "EXECUTION_FAILED",
    NVJPEG_STATUS_ARCH_MISMATCH                 : "ARCH_MISMATCH",
    NVJPEG_STATUS_INTERNAL_ERROR                : "INTERNAL_ERROR",
    NVJPEG_STATUS_IMPLEMENTATION_NOT_SUPPORTED  : "IMPLEMENTATION_NOT_SUPPORTED",
    }

CSS_STR = {
    NVJPEG_CSS_444  : "444",
    NVJPEG_CSS_422  : "422",
    NVJPEG_CSS_420  : "420",
    NVJPEG_CSS_440  : "440",
    NVJPEG_CSS_411  : "411",
    NVJPEG_CSS_410  : "410",
    NVJPEG_CSS_GRAY : "gray",
    NVJPEG_CSS_UNKNOWN  : "unknown",
    }

ENCODING_STR = {
    NVJPEG_ENCODING_UNKNOWN                         : "unknown",
    NVJPEG_ENCODING_BASELINE_DCT                    : "baseline-dct",
    NVJPEG_ENCODING_EXTENDED_SEQUENTIAL_DCT_HUFFMAN : "extended-sequential-dct-huffman",
    NVJPEG_ENCODING_PROGRESSIVE_DCT_HUFFMAN         : "progressive-dct-huffman",
    }

NVJPEG_INPUT_STR = {
    NVJPEG_INPUT_RGB    : "RGB",
    NVJPEG_INPUT_BGR    : "BGR",
    NVJPEG_INPUT_RGBI   : "RGBI",
    NVJPEG_INPUT_BGRI   : "BGRI",
    }


def get_version():
    cdef int major_version, minor_version, patch_level
    r = nvjpegGetProperty(MAJOR_VERSION, &major_version)
    errcheck(r, "nvjpegGetProperty MAJOR_VERSION")
    r = nvjpegGetProperty(MINOR_VERSION, &minor_version)
    errcheck(r, "nvjpegGetProperty MINOR_VERSION")
    r = nvjpegGetProperty(PATCH_LEVEL, &patch_level)
    errcheck(r, "nvjpegGetProperty PATCH_LEVEL")
    return (major_version, minor_version, patch_level)

def get_type() -> str:
    return "nvjpeg"

def get_encodings():
    return ("jpeg", "jpega")

def get_info():
    return {"version"   : get_version()}

def init_module():
    log("nvjpeg.init_module() version=%s", get_version())

def cleanup_module():
    log("nvjpeg.cleanup_module()")

NVJPEG_INPUT_FORMATS = {
    "jpeg"  : ("BGRX", "RGBX", ),
    "jpega"  : ("BGRA", "RGBA", ),
    }

def get_input_colorspaces(encoding):
    assert encoding in ("jpeg", "jpega")
    return NVJPEG_INPUT_FORMATS[encoding]

def get_output_colorspaces(encoding, input_colorspace):
    assert encoding in ("jpeg", "jpega")
    assert input_colorspace in get_input_colorspaces(encoding)
    return NVJPEG_INPUT_FORMATS[encoding]

def get_spec(encoding, colorspace):
    assert encoding in ("jpeg", "jpega")
    assert colorspace in get_input_colorspaces(encoding)
    from xpra.codecs.codec_constants import video_spec
    return video_spec("jpeg", input_colorspace=colorspace, output_colorspaces=(colorspace, ),
                      has_lossless_mode=False,
                      codec_class=Encoder, codec_type="jpeg",
                      setup_cost=20, cpu_cost=0, gpu_cost=100,
                      min_w=16, min_h=16, max_w=16*1024, max_h=16*1024,
                      can_scale=True,
                      score_boost=-50)


cdef class Encoder:
    cdef unsigned int width
    cdef unsigned int height
    cdef unsigned int encoder_width
    cdef unsigned int encoder_height
    cdef object encoding
    cdef object src_format
    cdef int quality
    cdef int speed
    cdef int grayscale
    cdef long frames
    cdef nvjpegHandle_t nv_handle
    cdef nvjpegEncoderState_t nv_enc_state
    cdef nvjpegEncoderParams_t nv_enc_params
    cdef nvjpegImage_t nv_image
    cdef cudaStream_t stream
    cdef cuda_kernel
    cdef object __weakref__

    def __init__(self):
        self.width = self.height = self.quality = self.speed = self.frames = 0

    def init_context(self, encoding, width : int, height : int, src_format, options : typedict):
        assert encoding in ("jpeg", "jpega")
        assert src_format in get_input_colorspaces(encoding)
        options = options or typedict()
        self.encoding = encoding
        self.width = width
        self.height = height
        self.encoder_width = options.intget("scaled-width", width)
        self.encoder_height = options.intget("scaled-height", height)
        self.src_format = src_format
        self.quality = options.intget("quality", 50)
        self.speed = options.intget("speed", 50)
        self.grayscale = options.boolget("grayscale", False)
        cuda_device_context = options.get("cuda-device-context")
        assert cuda_device_context, "no cuda device context"
        if encoding=="jpeg":
            kernel_name = "%s_to_RGB" % src_format
        else:
            kernel_name = "%s_to_RGBAP" % src_format
        with cuda_device_context:
            self.cuda_kernel = get_CUDA_function(kernel_name)
        if not self.cuda_kernel:
            raise Exception("missing %s kernel" % kernel_name)
        self.init_nvjpeg()

    def init_nvjpeg(self):
        # initialize nvjpeg structures
        errcheck(nvjpegCreateSimple(&self.nv_handle), "nvjpegCreateSimple")
        errcheck(nvjpegEncoderStateCreate(self.nv_handle, &self.nv_enc_state, self.stream), "nvjpegEncoderStateCreate")
        errcheck(nvjpegEncoderParamsCreate(self.nv_handle, &self.nv_enc_params, self.stream), "nvjpegEncoderParamsCreate")
        self.configure_nvjpeg()

    def configure_nvjpeg(self):
        self.configure_subsampling(self.grayscale)
        self.configure_quality(self.quality)
        cdef int huffman = int(self.speed<80)
        r = nvjpegEncoderParamsSetOptimizedHuffman(self.nv_enc_params, huffman, self.stream)
        errcheck(r, "nvjpegEncoderParamsSetOptimizedHuffman %i", huffman)
        log("configure_nvjpeg() nv_handle=%#x, nv_enc_state=%#x, nv_enc_params=%#x",
            <uintptr_t> self.nv_handle, <uintptr_t> self.nv_enc_state, <uintptr_t> self.nv_enc_params)
        cdef nvjpegJpegEncoding_t encoding_type = NVJPEG_ENCODING_BASELINE_DCT
        #NVJPEG_ENCODING_EXTENDED_SEQUENTIAL_DCT_HUFFMAN
        #NVJPEG_ENCODING_PROGRESSIVE_DCT_HUFFMAN
        r = nvjpegEncoderParamsSetEncoding(self.nv_enc_params, encoding_type, self.stream)
        errcheck(r, "nvjpegEncoderParamsSetEncoding %i (%s)", encoding_type, ENCODING_STR.get(encoding_type, "invalid"))
        log("configure_nvjpeg() quality=%s, huffman=%s, encoding type=%s",
            self.quality, huffman, ENCODING_STR.get(encoding_type, "invalid"))

    def configure_subsampling(self, grayscale=False):
        cdef nvjpegChromaSubsampling_t subsampling
        if grayscale:
            subsampling = NVJPEG_CSS_GRAY
        else:
            subsampling = get_subsampling(self.quality)
        cdef int r
        r = nvjpegEncoderParamsSetSamplingFactors(self.nv_enc_params, subsampling, self.stream)
        errcheck(r, "nvjpegEncoderParamsSetSamplingFactors %i (%s)",
                 <const nvjpegChromaSubsampling_t> subsampling, CSS_STR.get(subsampling, "invalid"))
        log("configure_subsampling(%s) using %s", grayscale, CSS_STR.get(subsampling, "invalid"))

    def configure_quality(self, int quality):
        cdef int r
        r = nvjpegEncoderParamsSetQuality(self.nv_enc_params, self.quality, self.stream)
        errcheck(r, "nvjpegEncoderParamsSetQuality %i", self.quality)

    def is_ready(self):
        return self.nv_handle!=NULL

    def is_closed(self):
        return self.nv_handle==NULL

    def clean(self):
        self.clean_cuda()
        self.clean_nvjpeg()

    def clean_cuda(self):
        self.cuda_kernel = None

    def clean_nvjpeg(self):
        log("nvjpeg.clean() nv_handle=%#x", <uintptr_t> self.nv_handle)
        if self.nv_handle==NULL:
            return
        self.width = self.height = self.encoder_width = self.encoder_height = self.quality = self.speed = 0
        cdef int r
        r = nvjpegEncoderParamsDestroy(self.nv_enc_params)
        errcheck(r, "nvjpegEncoderParamsDestroy %#x", <uintptr_t> self.nv_enc_params)
        r = nvjpegEncoderStateDestroy(self.nv_enc_state)
        errcheck(r, "nvjpegEncoderStateDestroy")
        r = nvjpegDestroy(self.nv_handle)
        errcheck(r, "nvjpegDestroy")
        self.nv_handle = NULL

    def get_encoding(self):
        return "jpeg"

    def get_width(self):
        return self.width

    def get_height(self):
        return self.height

    def get_type(self):
        return "nvjpeg"

    def get_src_format(self):
        return self.src_format

    def get_info(self) -> dict:
        info = get_info()
        info.update({
            "frames"        : int(self.frames),
            "width"         : self.width,
            "height"        : self.height,
            "speed"         : self.speed,
            "quality"       : self.quality,
            })
        return info

    def compress_image(self, image, options=None):
        options = options or {}
        cuda_device_context = options.get("cuda-device-context")
        assert cuda_device_context, "no cuda device context"
        pfstr = image.get_pixel_format()
        assert pfstr==self.src_format, "invalid pixel format %s, expected %s" % (pfstr, self.src_format)
        cdef nvjpegInputFormat_t input_format
        quality = options.get("quality", -1)
        if quality>=0 and abs(self.quality-quality)>10:
            self.quality = quality
            self.configure_nvjpeg()
        cdef int width = image.get_width()
        cdef int height = image.get_height()
        cdef int src_stride = image.get_rowstride()
        cdef int dst_stride
        pixels = image.get_pixels()
        cdef Py_ssize_t buf_len = len(pixels)
        cdef double start, end
        cdef size_t length
        cdef MemBuf output_buf
        cdef uintptr_t channel_ptr
        cdef unsigned char* buf_ptr
        for i in range(NVJPEG_MAX_COMPONENT):
            self.nv_image.channel[i] = NULL
            self.nv_image.pitch[i] = 0
        with cuda_device_context as cuda_context:
            start = monotonic()
            #upload raw BGRX / BGRA (or RGBX / RGBA):
            upload_buffer = driver.mem_alloc(buf_len)
            driver.memcpy_htod(upload_buffer, pixels)
            end = monotonic()
            log("nvjpeg: uploaded %i bytes of %s to CUDA buffer %#x in %.1fms",
                buf_len, self.src_format, int(upload_buffer), 1000*(end-start))
            #convert to RGB(A) + scale:
            start = monotonic()
            d = cuda_device_context.device
            da = driver.device_attribute
            blockw = min(32, d.get_attribute(da.MAX_BLOCK_DIM_X))
            blockh = min(32, d.get_attribute(da.MAX_BLOCK_DIM_Y))
            gridw = max(1, ceil(width/blockw))
            gridh = max(1, ceil(height/blockh))
            buffers = []
            if self.encoding=="jpeg":
                #use a single RGB buffer as input to the encoder:
                nchannels = 1
                input_format = NVJPEG_INPUT_RGBI
                rgb_buffer, dst_stride = driver.mem_alloc_pitch(self.encoder_width*3, self.encoder_height, 16)
                buffers.append(rgb_buffer)
            else:
                #use planar RGBA:
                nchannels = 4
                input_format = NVJPEG_INPUT_RGB
                dst_stride = 0
                for i in range(nchannels):
                    planar_buffer, planar_stride = driver.mem_alloc_pitch(self.encoder_width, self.encoder_height, 16)
                    buffers.append(planar_buffer)
                    if dst_stride==0:
                        dst_stride = planar_stride
                    else:
                        #all planes are the same size, should get the same stride:
                        assert dst_stride==planar_stride
            def free_buffers():
                for buf in buffers:
                    buf.free()
            args = [
                numpy.int32(width), numpy.int32(height),
                numpy.int32(src_stride), upload_buffer,
                numpy.int32(self.encoder_width), numpy.int32(self.encoder_height),
                numpy.int32(dst_stride),
                ]
            for i in range(nchannels):
                args.append(buffers[i])
                channel_ptr = <uintptr_t> int(buffers[i])
                self.nv_image.channel[i] = <unsigned char *> channel_ptr
                self.nv_image.pitch[i] = dst_stride
            log("nvjpeg calling kernel with %s", args)
            self.cuda_kernel(*args, block=(blockw, blockh, 1), grid=(gridw, gridh))
            cuda_context.synchronize()
            upload_buffer.free()
            del upload_buffer
            end = monotonic()
            log("nvjpeg: csc / scaling took %.1fms", 1000*(end-start))
            #now we actuall compress the rgb buffer:
            start = monotonic()
            with nogil:
                r = nvjpegEncodeImage(self.nv_handle, self.nv_enc_state, self.nv_enc_params,
                                      &self.nv_image, input_format, self.encoder_width, self.encoder_height, self.stream)
            errcheck(r, "nvjpegEncodeImage")
            end = monotonic()
            log("nvjpeg: nvjpegEncodeImage took %.1fms using input format %s",
                1000*(end-start), NVJPEG_INPUT_STR.get(input_format, input_format))
            self.frames += 1
            #r = cudaStreamSynchronize(stream)
            #if not r:
            #    raise Exception("nvjpeg failed to synchronize cuda stream: %i" % r)
            # get compressed stream size
            start = monotonic()
            r = nvjpegEncodeRetrieveBitstream(self.nv_handle, self.nv_enc_state, NULL, &length, self.stream)
            errcheck(r, "nvjpegEncodeRetrieveBitstream")
            output_buf = getbuf(length)
            buf_ptr = <unsigned char*> output_buf.get_mem()
            with nogil:
                r = nvjpegEncodeRetrieveBitstream(self.nv_handle, self.nv_enc_state, buf_ptr, &length, NULL)
            errcheck(r, "nvjpegEncodeRetrieveBitstream")
            end = monotonic()
            log("nvjpeg: downloaded %i jpeg bytes in %.1fms", length, 1000*(end-start))
            if self.encoding=="jpeg":
                free_buffers()
                return memoryview(output_buf), {}
            #now compress alpha:
            jpeg = memoryview(output_buf).tobytes()
            start = monotonic()
            #set RGB to the alpha channel:
            for i in range(3):
                self.nv_image.channel[i] = self.nv_image.channel[3]
                self.nv_image.pitch[i] = self.nv_image.pitch[3]
            self.nv_image.channel[3] = NULL
            self.nv_image.pitch[3] = 0
            try:
                #tweak settings temporarily:
                if not self.grayscale:
                    self.configure_subsampling(True)
                if self.quality<100:
                    self.configure_quality(100)
                with nogil:
                    r = nvjpegEncodeImage(self.nv_handle, self.nv_enc_state, self.nv_enc_params,
                                          &self.nv_image, input_format, self.encoder_width, self.encoder_height, self.stream)
                errcheck(r, "nvjpegEncodeImage")
                r = nvjpegEncodeRetrieveBitstream(self.nv_handle, self.nv_enc_state, NULL, &length, self.stream)
                errcheck(r, "nvjpegEncodeRetrieveBitstream")
                output_buf = getbuf(length)
                buf_ptr = <unsigned char*> output_buf.get_mem()
                r = nvjpegEncodeRetrieveBitstream(self.nv_handle, self.nv_enc_state, buf_ptr, &length, NULL)
                errcheck(r, "nvjpegEncodeRetrieveBitstream")
                end = monotonic()
                log("nvjpeg: downloaded %i alpha bytes in %.1fms", length, 1000*(end-start))
                jpega = memoryview(output_buf).tobytes()
                return jpeg+jpega, {"alpha-offset" : len(jpeg)}
            finally:
                free_buffers()
                #restore settings:
                if not self.grayscale:
                    self.configure_subsampling(False)
                if self.quality<100:
                    self.configure_quality(self.quality)

class NVJPEG_Exception(Exception):
    pass

def errcheck(int r, fnname="", *args):
    if r:
        fstr = fnname % (args)
        raise NVJPEG_Exception("%s failed: %s" % (fstr, ERR_STRS.get(r, r)))


def compress_file(filename, save_to="./out.jpeg"):
    from PIL import Image
    img = Image.open(filename)
    rgb_format = "RGB"
    img = img.convert(rgb_format)
    w, h = img.size
    stride = w*len(rgb_format)
    data = img.tobytes("raw", img.mode)
    log("data=%i bytes (%s) for %s", len(data), type(data), img.mode)
    log("w=%i, h=%i, stride=%i, size=%i", w, h, stride, stride*h)
    from xpra.codecs.image_wrapper import ImageWrapper
    image = ImageWrapper(0, 0, w, h, data, rgb_format,
                       len(rgb_format)*8, stride, len(rgb_format), ImageWrapper.PACKED, True, None)
    jpeg_data = encode("jpeg", image)[0]
    with open(save_to, "wb") as f:
        f.write(jpeg_data)

cdef nvjpegChromaSubsampling_t get_subsampling(int quality):
    if quality>=80:
        return NVJPEG_CSS_444
    if quality>=60:
        return NVJPEG_CSS_422
    return NVJPEG_CSS_420


def get_device_context():
    from xpra.codecs.cuda_common.cuda_context import select_device, cuda_device_context
    cdef double start = monotonic()
    cuda_device_id, cuda_device = select_device()
    if cuda_device_id<0 or not cuda_device:
        raise Exception("failed to select a cuda device")
    log("using device %s", cuda_device)
    cuda_context = cuda_device_context(cuda_device_id, cuda_device)
    cdef double end = monotonic()
    log("device init took %.1fms", 1000*(end-start))
    return cuda_context

errors = []
def get_errors():
    global errors
    return errors

def encode(coding, image, options=None):
    assert coding in ("jpeg", "jpega"), "invalid encoding: %s" % coding
    global errors
    pfstr = image.get_pixel_format()
    width = image.get_width()
    height = image.get_height()
    cdef double start, end
    input_formats = NVJPEG_INPUT_FORMATS[coding]
    if pfstr not in input_formats:
        from xpra.codecs.argb.argb import argb_swap         #@UnresolvedImport @Reimport
        start = monotonic()
        oldpfstr = pfstr
        if not argb_swap(image, input_formats):
            log("nvjpeg: argb_swap failed to convert %s to a suitable format: %s" % (
                pfstr, input_formats))
            return None
        pfstr = image.get_pixel_format()
        end = monotonic()
        log("nvjpeg: argb_swap converted %s to %s in %.1fms", oldpfstr, pfstr, 1000*(end-start))

    options = typedict(options or {})
    if "cuda-device-context" not in options:
        options["cuda-device-context"] = get_device_context()
    cdef Encoder encoder
    try:
        encoder = Encoder()
        encoder.init_context(coding, width, height, pfstr, options=options)
        r = encoder.compress_image(image, options)
        if not r:
            return None
        cdata, options = r
        may_save_image("jpeg", cdata)
        return coding, Compressed(coding, cdata, False), options, width, height, 0, 24
    except NVJPEG_Exception as e:
        errors.append(str(e))
        return None
    finally:
        encoder.clean()


def selftest(full=False):
    #this is expensive, so don't run it unless "full" is set:
    from xpra.codecs.codec_checks import make_test_image
    options = {
        "cuda-device-context"   : get_device_context(),
        }
    for width, height in ((32, 32), (256, 80), (1920, 1080)):
        for encoding, input_formats in NVJPEG_INPUT_FORMATS.items():
            for fmt in input_formats:
                img = make_test_image(fmt, width, height)
                log("testing with %s", img)
                v = encode(encoding, img, options)
                assert v, "failed to compress test image"
