//
// Copyright © 2019 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "TargetConditionals.h"
#import "UTMScreenshot.h"
#import "UTMShaderTypes.h"
#import "CocoaSpice.h"
#import "UTMLogging.h"
#import <glib.h>
#import <spice-client.h>
#import <spice/protocol.h>

#define DISPLAY_DEBUG(display, fmt, ...) \
    SPICE_DEBUG("%d:%d " fmt, \
                (int)display.channelID, \
                (int)display.monitorID, \
                ## __VA_ARGS__)

@interface CSDisplayMetal ()

@property (nonatomic, readwrite, nullable) SpiceSession *session;
@property (nonatomic, readwrite, assign) NSInteger channelID;
@property (nonatomic, readwrite, assign) NSInteger monitorID;

@end

@implementation CSDisplayMetal {
    SpiceDisplayChannel     *_display;
    SpiceMainChannel        *_main;
    
    BOOL                    _sigsconnected;
    
    //gint                    _mark;
    gint                    _canvasFormat;
    gint                    _canvasStride;
    const void              *_canvasData;
    CGRect                  _canvasArea;
    CGRect                  _visibleArea;
    GWeakRef                _overlay_weak_ref;
    id<MTLDevice>           _device;
    id<MTLTexture>          _texture;
    id<MTLBuffer>           _vertices;
    NSUInteger              _numVertices;
    dispatch_semaphore_t    _drawLock;
}

static void cs_primary_create(SpiceChannel *channel, gint format,
                           gint width, gint height, gint stride,
                           gint shmid, gpointer imgdata, gpointer data) {
    CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
    
    g_assert(format == SPICE_SURFACE_FMT_32_xRGB || format == SPICE_SURFACE_FMT_16_555);
    dispatch_semaphore_wait(self->_drawLock, DISPATCH_TIME_FOREVER);
    self->_canvasArea = CGRectMake(0, 0, width, height);
    self->_canvasFormat = format;
    self->_canvasStride = stride;
    self->_canvasData = imgdata;
    dispatch_semaphore_signal(self->_drawLock);
    
    cs_update_monitor_area(channel, NULL, data);
}

static void cs_primary_destroy(SpiceDisplayChannel *channel, gpointer data) {
    CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
    self.ready = NO;
    
    dispatch_semaphore_wait(self->_drawLock, DISPATCH_TIME_FOREVER);
    self->_canvasArea = CGRectZero;
    self->_canvasFormat = 0;
    self->_canvasStride = 0;
    self->_canvasData = NULL;
    dispatch_semaphore_signal(self->_drawLock);
}

static void cs_invalidate(SpiceChannel *channel,
                       gint x, gint y, gint w, gint h, gpointer data) {
    CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
    CGRect rect = CGRectIntersection(CGRectMake(x, y, w, h), self->_visibleArea);
    if (!CGRectIsEmpty(rect)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self drawRegion:rect];
        });
    }
}

static void cs_mark(SpiceChannel *channel, gint mark, gpointer data) {
    //CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
    //@synchronized (self) {
    //    self->_mark = mark; // currently this does nothing for us
    //}
}

static gboolean cs_set_overlay(SpiceChannel *channel, void* pipeline_ptr, gpointer data) {
    CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
#warning Unimplemented
    return false;
}

static void cs_update_monitor_area(SpiceChannel *channel, GParamSpec *pspec, gpointer data) {
    CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
    SpiceDisplayMonitorConfig *cfg, *c = NULL;
    GArray *monitors = NULL;
    int i;
    
    DISPLAY_DEBUG(self, "update monitor area");
    if (self.monitorID < 0)
        goto whole;
    
    g_object_get(self->_display, "monitors", &monitors, NULL);
    for (i = 0; monitors != NULL && i < monitors->len; i++) {
        cfg = &g_array_index(monitors, SpiceDisplayMonitorConfig, i);
        if (cfg->id == self.monitorID) {
            c = cfg;
            break;
        }
    }
    if (c == NULL) {
        DISPLAY_DEBUG(self, "update monitor: no monitor %d", (int)self.monitorID);
        self.ready = NO;
        if (spice_channel_test_capability(SPICE_CHANNEL(self->_display),
                                          SPICE_DISPLAY_CAP_MONITORS_CONFIG)) {
            DISPLAY_DEBUG(self, "waiting until MonitorsConfig is received");
            g_clear_pointer(&monitors, g_array_unref);
            return;
        }
        goto whole;
    }
    
    if (c->surface_id != 0) {
        g_warning("FIXME: only support monitor config with primary surface 0, "
                  "but given config surface %u", c->surface_id);
        goto whole;
    }
    
    /* If only one head on this monitor, update the whole area */
    if (monitors->len == 1) {
        [self updateVisibleAreaWithRect:CGRectMake(0, 0, c->width, c->height)];
    } else {
        [self updateVisibleAreaWithRect:CGRectMake(c->x, c->y, c->width, c->height)];
    }
    self.ready = YES;
    g_clear_pointer(&monitors, g_array_unref);
    return;
    
whole:
    g_clear_pointer(&monitors, g_array_unref);
    /* by display whole surface */
    [self updateVisibleAreaWithRect:self->_canvasArea];
    self.ready = YES;
}

static void cs_channel_new(SpiceSession *s, SpiceChannel *channel, gpointer data) {
    CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
    gint channel_id;
    
    g_object_get(channel, "channel-id", &channel_id, NULL);
    
    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        SpiceDisplayPrimary primary;
        if (channel_id != self.channelID) {
            return;
        }
        self->_display = SPICE_DISPLAY_CHANNEL(channel);
        NSCAssert(!self->_sigsconnected, @"Signals already connected!");
        UTMLog(@"%s:%d", __FUNCTION__, __LINE__);
        g_signal_connect(channel, "display-primary-create",
                         G_CALLBACK(cs_primary_create), GLIB_OBJC_RETAIN(self));
        g_signal_connect(channel, "display-primary-destroy",
                         G_CALLBACK(cs_primary_destroy), GLIB_OBJC_RETAIN(self));
        g_signal_connect(channel, "display-invalidate",
                         G_CALLBACK(cs_invalidate), GLIB_OBJC_RETAIN(self));
        g_signal_connect_after(channel, "display-mark",
                               G_CALLBACK(cs_mark), GLIB_OBJC_RETAIN(self));
        g_signal_connect_after(channel, "notify::monitors",
                               G_CALLBACK(cs_update_monitor_area), GLIB_OBJC_RETAIN(self));
        g_signal_connect_after(channel, "gst-video-overlay",
                               G_CALLBACK(cs_set_overlay), GLIB_OBJC_RETAIN(self));
        self->_sigsconnected = YES;
        if (spice_display_channel_get_primary(channel, 0, &primary)) {
            cs_primary_create(channel, primary.format, primary.width, primary.height,
                              primary.stride, primary.shmid, primary.data, (__bridge void *)self);
            cs_mark(channel, primary.marked, (__bridge void *)self);
        }
        
        spice_channel_connect(channel);
        return;
    }
    
    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        self->_main = SPICE_MAIN_CHANNEL(channel);
        return;
    }
}

static void cs_channel_destroy(SpiceSession *s, SpiceChannel *channel, gpointer data) {
    CSDisplayMetal *self = (__bridge CSDisplayMetal *)data;
    gint channel_id;
    
    g_object_get(channel, "channel-id", &channel_id, NULL);
    DISPLAY_DEBUG(self, "channel_destroy %d", channel_id);
    
    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        if (channel_id != self.channelID) {
            return;
        }
        cs_primary_destroy(self->_display, (__bridge void *)self);
        self->_display = NULL;
        NSCAssert(self->_sigsconnected, @"Signals not connected!");
        UTMLog(@"%s:%d", __FUNCTION__, __LINE__);
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_primary_create), GLIB_OBJC_RELEASE(self));
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_primary_destroy), GLIB_OBJC_RELEASE(self));
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_invalidate), GLIB_OBJC_RELEASE(self));
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_mark), GLIB_OBJC_RELEASE(self));
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_update_monitor_area), GLIB_OBJC_RELEASE(self));
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_set_overlay), GLIB_OBJC_RELEASE(self));
        self->_sigsconnected = NO;
        return;
    }
    
    return;
}

- (void)setDevice:(id<MTLDevice>)device {
    _device = device;
    [self rebuildTexture];
    [self rebuildVertices];
}

- (id<MTLDevice>)device {
    return _device;
}

- (UTMScreenshot *)screenshot {
    CGImageRef img;
    CGColorSpaceRef colorSpaceRef = CGColorSpaceCreateDeviceRGB();
    
    dispatch_semaphore_wait(_drawLock, DISPATCH_TIME_FOREVER); // TODO: separate read lock so we don't block texture copy
    if (_canvasData) { // may be destroyed at this point
        CGDataProviderRef dataProviderRef = CGDataProviderCreateWithData(NULL, _canvasData, _canvasStride * _canvasArea.size.height, nil);
        img = CGImageCreate(_canvasArea.size.width, _canvasArea.size.height, 8, 32, _canvasStride, colorSpaceRef, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, dataProviderRef, NULL, NO, kCGRenderingIntentDefault);
        CGDataProviderRelease(dataProviderRef);
    } else {
        img = NULL;
    }
    dispatch_semaphore_signal(_drawLock);
    
    CGColorSpaceRelease(colorSpaceRef);
    
    if (img) {
#if TARGET_OS_IPHONE
        UIImage *uiimg = [UIImage imageWithCGImage:img];
#else
        NSImage *uiimg = [[NSImage alloc] initWithCGImage:img size:NSZeroSize];
#endif
        CGImageRelease(img);
        return [[UTMScreenshot alloc] initWithImage:uiimg];
    } else {
        return UTMScreenshot.none;
    }
}

@synthesize drawLock = _drawLock;
@synthesize texture = _texture;
@synthesize numVertices = _numVertices;
@synthesize vertices = _vertices;
@synthesize viewportOrigin;
@synthesize viewportScale;

- (id)init {
    self = [super init];
    if (self) {
        _drawLock = dispatch_semaphore_create(1);
        self.viewportScale = 1.0f;
        self.viewportOrigin = CGPointMake(0, 0);
    }
    return self;
}

- (id)initWithSession:(nonnull SpiceSession *)session channelID:(NSInteger)channelID monitorID:(NSInteger)monitorID {
    self = [self init];
    if (self) {
        GList *list;
        GList *it;
        
        self.channelID = channelID;
        self.monitorID = monitorID;
        self.session = session;
        _sigsconnected = NO;
        g_object_ref(session);
        
        UTMLog(@"%s:%d", __FUNCTION__, __LINE__);
        g_signal_connect(session, "channel-new",
                         G_CALLBACK(cs_channel_new), GLIB_OBJC_RETAIN(self));
        g_signal_connect(session, "channel-destroy",
                         G_CALLBACK(cs_channel_destroy), GLIB_OBJC_RETAIN(self));
        list = spice_session_get_channels(session);
        for (it = g_list_first(list); it != NULL; it = g_list_next(it)) {
            if (SPICE_IS_DISPLAY_CHANNEL(it->data) || SPICE_IS_MAIN_CHANNEL(it->data)) {
                cs_channel_new(session, it->data, (__bridge void *)self);
            }
        }
        g_list_free(list);
    }
    return self;
}

- (id)initWithSession:(nonnull SpiceSession *)session channelID:(NSInteger)channelID {
    return [self initWithSession:session channelID:channelID monitorID:0];
}

- (void)dealloc {
    if (_display) {
        cs_channel_destroy(self.session, SPICE_CHANNEL(_display), (__bridge void *)self);
    }
    UTMLog(@"%s:%d", __FUNCTION__, __LINE__);
    g_signal_handlers_disconnect_by_func(self.session, G_CALLBACK(cs_channel_new), GLIB_OBJC_RELEASE(self));
    g_signal_handlers_disconnect_by_func(self.session, G_CALLBACK(cs_channel_destroy), GLIB_OBJC_RELEASE(self));
    g_object_unref(self.session);
    self.session = NULL;
}

- (void)updateVisibleAreaWithRect:(CGRect)rect {
    CGRect visible = CGRectIntersection(_canvasArea, rect);
    if (CGRectIsNull(visible)) {
        DISPLAY_DEBUG(self, "The monitor area is not intersecting primary surface");
        self.ready = NO;
        _visibleArea = CGRectZero;
    } else {
        _visibleArea = visible;
    }
    self.displaySize = _visibleArea.size;
    [self rebuildTexture];
    [self rebuildVertices];
}

- (void)rebuildTexture {
    if (CGRectIsEmpty(_canvasArea) || !_device) {
        return;
    }
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];
    // don't worry that that components are reversed, we fix it in shaders
    textureDescriptor.pixelFormat = (_canvasFormat == SPICE_SURFACE_FMT_32_xRGB) ? MTLPixelFormatBGRA8Unorm : (MTLPixelFormat)43;// FIXME: MTLPixelFormatBGR5A1Unorm is supposed to be available.
    textureDescriptor.width = _visibleArea.size.width;
    textureDescriptor.height = _visibleArea.size.height;
    dispatch_semaphore_wait(_drawLock, DISPATCH_TIME_FOREVER);
    _texture = [_device newTextureWithDescriptor:textureDescriptor];
    dispatch_semaphore_signal(_drawLock);
    [self drawRegion:_visibleArea];
}

- (void)rebuildVertices {
    // We flip the y-coordinates because pixman renders flipped
    UTMVertex quadVertices[] =
    {
        // Pixel positions, Texture coordinates
        { {  _visibleArea.size.width/2,   _visibleArea.size.height/2 },  { 1.f, 0.f } },
        { { -_visibleArea.size.width/2,   _visibleArea.size.height/2 },  { 0.f, 0.f } },
        { { -_visibleArea.size.width/2,  -_visibleArea.size.height/2 },  { 0.f, 1.f } },
        
        { {  _visibleArea.size.width/2,   _visibleArea.size.height/2 },  { 1.f, 0.f } },
        { { -_visibleArea.size.width/2,  -_visibleArea.size.height/2 },  { 0.f, 1.f } },
        { {  _visibleArea.size.width/2,  -_visibleArea.size.height/2 },  { 1.f, 1.f } },
    };
    
    dispatch_semaphore_wait(_drawLock, DISPATCH_TIME_FOREVER);
    // Create our vertex buffer, and initialize it with our quadVertices array
    _vertices = [_device newBufferWithBytes:quadVertices
                                     length:sizeof(quadVertices)
                                    options:MTLResourceStorageModeShared];

    // Calculate the number of vertices by dividing the byte length by the size of each vertex
    _numVertices = sizeof(quadVertices) / sizeof(UTMVertex);
    dispatch_semaphore_signal(_drawLock);
}

- (void)drawRegion:(CGRect)rect {
    NSInteger pixelSize = (_canvasFormat == SPICE_SURFACE_FMT_32_xRGB) ? 4 : 2;
    // create draw region
    MTLRegion region = {
        { rect.origin.x-_visibleArea.origin.x, rect.origin.y-_visibleArea.origin.y, 0 }, // MTLOrigin
        { rect.size.width, rect.size.height, 1} // MTLSize
    };
    dispatch_semaphore_wait(_drawLock, DISPATCH_TIME_FOREVER);
    if (_canvasData != NULL) { // canvas may be destroyed by this time
        [_texture replaceRegion:region
                    mipmapLevel:0
                      withBytes:(const char *)_canvasData + (NSUInteger)(rect.origin.y*_canvasStride + rect.origin.x*pixelSize)
                    bytesPerRow:_canvasStride];
    }
    dispatch_semaphore_signal(_drawLock);
}

- (BOOL)visible {
    return self.ready;
}

- (void)requestResolution:(CGRect)bounds {
    [self requestResolution:bounds monitorID:self.monitorID];
}

- (void)requestResolution:(CGRect)bounds monitorID:(NSInteger)monitorID {
    
    if (!_main) {
        UTMLog(@"ignoring change resolution because main channel not found");
        return;
    }
    spice_main_channel_update_display_enabled(_main, (int)monitorID, TRUE, FALSE);
    spice_main_channel_update_display(_main,
                                      (int)monitorID,
                                      bounds.origin.x,
                                      bounds.origin.y,
                                      bounds.size.width,
                                      bounds.size.height,
                                      TRUE);
    spice_main_channel_send_monitor_config(_main);
}

@end
