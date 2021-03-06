#if defined(type) && defined(real) && defined(BROU_METAL) && defined(BROU_OBJECT)

@interface BROU_OBJECT(FullConnectLayer)() {
    /**the input features channel*/
    int _inputChannel;
    
    /**the output feature channel*/
    int _outputChannel;
    
    /**
     * _inputChannelX4 >= inputchannel and timed by 4
     * _inputChannelX4 >= outputChannel and timed by 4
     */
    int _inputChannelX4;
    int _outputChannelX4;
    
    /**if the convolution has a bias*/
    bool _haveBias;
    
    /**store the kernel and bias*/
    id<MTLBuffer> _weigths;
    id<MTLBuffer> _bias;
    
    id<MTLBuffer> _shape;
    
    /**the MTL function name*/
    NSString *_functionName;
    
    /**the Metal computePipelineState*/
    id<MTLComputePipelineState> _computePipelineState;
}

@end

@implementation BROU_OBJECT(FullConnectLayer)

- (instancetype)initWithDevice:(id<MTLDevice>)device
                       library:(id<MTLLibrary>)library
                  floatWeights:(void*)floatWeight
                     floatBias:(void*)floatBias
                 intputChannel:(int)inputChannel
                 outputChannel:(int)outputChannel {
    self = [super initWithName:@BROU_OBJECT_NAME(FullConnectLayer)];
    
    if (!self) {
        return self;
    }
    
    [self configParamsWithInputChannel:inputChannel outputChannel:outputChannel];
    [self configBufferWithDevice:device floatKernel:floatWeight];
    [self configBufferWithDevice:device floatBias:floatBias];
    [self configComputePipelinesStateWithDevice:device library:library];
    
    if (@available(iOS 9.0, *)) {
        _shape = [device newBufferWithLength:sizeof(TensorShape)
                                     options:MTLResourceCPUCacheModeDefaultCache | MTLResourceStorageModeShared];
    } else {
        _shape = [device newBufferWithLength:sizeof(TensorShape)
                                     options:MTLResourceCPUCacheModeDefaultCache];
    }
    
    TensorShape *shapeRef = (TensorShape*)_shape.contents;
    shapeRef->dim0 = _inputChannelX4;
    shapeRef->dim1 = _outputChannelX4;
    
    return self;
}

- (void)configParamsWithInputChannel:(int)inputChannel
                       outputChannel:(int)outputChannel {
    NSAssert(inputChannel  > 0, @"the inputchannel must > 0");
    NSAssert(outputChannel > 0, @"the outputChannel must > 0");
    
    _inputChannel  = inputChannel;
    _outputChannel = outputChannel;
    
    _inputChannelX4  = (_inputChannel  + 3) / 4 * 4;
    _outputChannelX4 = (_outputChannel + 3) / 4 * 4;
}

- (void)configComputePipelinesStateWithDevice:(id<MTLDevice>)device
                                      library:(id<MTLLibrary>)library {
    if (_haveBias) {
        _functionName = @BROU_METAL(Fullconnect);
    } else {
        _functionName = @BROU_METAL(FullconnectWithoutBias);
    }
    
    id<MTLFunction> function = [library newFunctionWithName:_functionName];
    
    NSAssert(function, @"init %@ function:%@ error!", self.name, _functionName);
    
    /**get the function*/
    NSError *error = nil;
    
    _computePipelineState = [device newComputePipelineStateWithFunction:function error:&error];
    
    NSAssert(_computePipelineState, @"init %@ ComputePipelineState error:%@", self.name, error);
}

- (void)configBufferWithDevice:(id<MTLDevice>)device floatKernel:(void*)floatKernel {
    void *realKernel = NULL;
    
#if defined(real_is_half)
    realKernel = malloc(sizeof(type) * _outputChannel * _inputChannel);
    
    convertFloat32ToFloat16(floatKernel,
                            realKernel,
                            _outputChannel * _inputChannel);
#elif defined(real_is_float)
    realKernel = floatKernel;
#endif
    
    if (@available(iOS 9.0, *)) {
        _weigths = [device newBufferWithLength:sizeof(type) * _outputChannelX4 * _inputChannelX4
                                       options:MTLResourceCPUCacheModeDefaultCache | MTLResourceStorageModeShared];
    } else {
        _weigths = [device newBufferWithLength:sizeof(type) * _outputChannelX4 * _inputChannelX4
                                       options:MTLResourceCPUCacheModeDefaultCache];
    }
    
    for (int i = 0; i < _outputChannel; ++i) {
        memcpy(_weigths.contents + i * sizeof(type) * _inputChannelX4,
               realKernel        + i * sizeof(type) * _inputChannel,
               sizeof(type) * _inputChannel);
    }
    
#if defined(real_is_half)
    free(realKernel);
#endif
}

- (void)configBufferWithDevice:(id<MTLDevice>)device floatBias:(void*)floatBias {
    if (NULL == floatBias) {
        _haveBias = false;
        return;
    }
    
    _haveBias = true;
    
    void *realBias = NULL;
    
#if defined(real_is_half)
    /**the real is half */
    realBias = malloc(sizeof(type) * _outputChannel);
    
    convertFloat32ToFloat16(floatBias,
                            realBias,
                            _outputChannel);
#elif defined(real_is_float)
    /**the real is float*/
    realBias = floatBias;
#endif
    
    if (@available(iOS 9.0, *)) {
        _bias = [device newBufferWithLength:sizeof(type) * _outputChannelX4
                                    options:MTLResourceCPUCacheModeDefaultCache | MTLResourceStorageModeShared];
    } else {
        _bias = [device newBufferWithLength:sizeof(type) * _outputChannelX4
                                    options:MTLResourceCPUCacheModeDefaultCache];
    }
    
    memcpy(_bias.contents, realBias, sizeof(type) * _outputChannel);
    
#if defined(real_is_half)
    free(realBias);
#endif
}

- (void)checkParamsWithInput:(id<BrouTensor>)input
                      output:(id<BrouTensor>)output {
    NSAssert(1 == input.dimension, @"The input tensor's dimension must be 1");
    NSAssert(_inputChannel == input.dim0, @"the dim of input is error");
    
    NSAssert(1 == output.dimension, @"The output tensor's dimension must be 1");
    NSAssert(_outputChannel == output.dim0, @"the dim of output is error");
}

- (void)computeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                       input:(id<BrouTensor>)input
                      output:(id<BrouTensor>)output {
    [self checkParamsWithInput:input output:output];
    
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    [encoder setComputePipelineState:_computePipelineState];
    
    if (_haveBias) {
        [encoder setBuffer:input.tensorBuffer  offset:0 atIndex:0];
        [encoder setBuffer:_weigths            offset:0 atIndex:1];
        [encoder setBuffer:_bias               offset:0 atIndex:2];
        [encoder setBuffer:output.tensorBuffer offset:0 atIndex:3];
        [encoder setBuffer:_shape              offset:0 atIndex:4];
    } else {
        [encoder setBuffer:input.tensorBuffer  offset:0 atIndex:0];
        [encoder setBuffer:_weigths            offset:0 atIndex:1];
        [encoder setBuffer:output.tensorBuffer offset:0 atIndex:2];
        [encoder setBuffer:_shape              offset:0 atIndex:3];
    }
    
    NSUInteger executeWidth = _computePipelineState.threadExecutionWidth;
    
    MTLSize group = MTLSizeMake(executeWidth, 1, 1);
    MTLSize grid  = MTLSizeMake((_outputChannelX4 + 4 * executeWidth - 1) / (4 * executeWidth), 1, 1);
    
    [encoder dispatchThreadgroups:grid threadsPerThreadgroup:group];
    [encoder endEncoding];
}


@end

#endif










