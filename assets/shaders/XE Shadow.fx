
// XE Shadow.fx
// MGE XE 0.11
// Shadow receiver functions (included by XE Main)

#include "XE Shadow Settings.fx"



//------------------------------------------------------------
// Texture atlas

// Clip space margin of 4 texels, to prevent bleeding from the filter kernel + adjacent textures
static float3 atlasMargin = float3(1-4*shadowRcpRes, 1-4*shadowRcpRes, 1);

// Shadow UV to shadow atlas UV
float4 mapShadowToAtlas(float2 t, int layer)
{
    // Result is intended for use with tex2Dlod
    return float4(t.x * shadowCascadeSize + layer * shadowCascadeSize, t.y, 0, 0);
}

//------------------------------------------------------------
// Incoming vertex sunlight estimation

float shadowSunEstimate(float lambert)
{
    float x = lambert * dot(SunCol, float3(0.36, 0.53, 0.11));
    x *= 0.25 + 0.75 * SunVis;
    return x / (shade + x);
}

//------------------------------------------------------------
// 2 layer cascade ortho ESM lookup

float shadowDeltaZ(float4 shadow0pos, float4 shadow1pos)
{
    float dz = 1e-6;
    
    [branch] if(all(saturate(atlasMargin - abs(shadow0pos.xyz))))
    {
        // Layer 0, inner
        float2 shadowUV = (0.5 + 0.5*shadowRcpRes) + float2(0.5, -0.5) * shadow0pos.xy;
        dz = tex2Dlod(sampDepth, mapShadowToAtlas(shadowUV, 0)).r / ESM_scale - shadow0pos.z;
    }
    else if(all(saturate(atlasMargin - abs(shadow1pos.xyz))))
    {
        // Layer 1
        float2 shadowUV = (0.5 + 0.5*shadowRcpRes) + float2(0.5, -0.5) * shadow1pos.xy;
        dz = tex2Dlod(sampDepth, mapShadowToAtlas(shadowUV, 1)).r / ESM_scale - shadow1pos.z;
    }
    
    return dz;
}

float shadowESM(float dz)
{
    return 1 - saturate(exp(ESM_c * dz + ESM_bias));
}

//------------------------------------------------------------
// Shadow reciever rendering

struct RenderShadowVertOut
{
    float4 pos: POSITION;
    half2 texcoords: TEXCOORD0;
    float light: COLOR0;
    
    float4 shadow0pos: TEXCOORD1;
    float4 shadow1pos: TEXCOORD2;
};

RenderShadowVertOut RenderShadowsVS (in MorrowindVertIn IN)
{
    RenderShadowVertOut OUT;
    float4 viewpos;
    float4 normal = float4(IN.normal.xyz, 0);

    // Skin mesh if required
    if(hasbones)
    {
        viewpos = skin(IN.pos, IN.blendweights);
        normal = skin(normal, IN.blendweights);
        normal = normalize(normal);
    }
    else
    {
        viewpos = mul(IN.pos, vertexblendpalette[0]);
        normal = mul(normal, vertexblendpalette[0]);
    }
    
    // Transform and depth bias to mitigate difference between FFP and VS
    OUT.pos = mul(viewpos, proj);
    OUT.pos.z *= 1 - 2e-6;
    OUT.pos.z -= clamp(0.5 / OUT.pos.w, 0, 1e-2);
    
    // Non-standard shadow luminance, to create sufficient contrast when ambient is high
    OUT.light = shadowSunEstimate(saturate(dot(normal.xyz, -SunVecView)));

    // Fog attenuation (shadow darkness and distance fade)
    float fogatt = pow(fogMWScalar(OUT.pos.w), 2);
    if(isAboveSeaLevel(EyePos))
        OUT.light *= fogatt;
    else
        OUT.light *= saturate(4 * fogatt);
    
    // Find position in light space, output light depth
    OUT.shadow0pos = mul(viewpos, shadowviewproj[0]);
    OUT.shadow1pos = mul(viewpos, shadowviewproj[1]);
    OUT.shadow0pos.z = OUT.shadow0pos.z / OUT.shadow0pos.w;
    OUT.shadow1pos.z = OUT.shadow1pos.z / OUT.shadow1pos.w;

    OUT.texcoords = IN.texcoords;
    return OUT;
}


float4 RenderShadowsPS (RenderShadowVertOut IN): COLOR0
{
    // Early reject unlit areas
    clip(IN.light - 2.0/255.0);
    
    // Respect alpha test
    float alpha = 1.0;
    if(hasalpha)
    {
        alpha = tex2D(sampBaseTex, IN.texcoords).a;
        clip(alpha - alpharef);
    }

    // Soft shadowing
    float dz = shadowDeltaZ(IN.shadow0pos, IN.shadow1pos);
    clip(-dz);
    float v = shadowESM(dz) * IN.light * alpha;
 
    // Darken shadow area according to existing lighting (slightly towards blue)
    clip(v - 2.0/255.0);
    return float4(v * shadecolour, 1);
}

//------------------------------------------------------------
// Shadow map debug inset display

struct DebugOut
{
    float4 pos : POSITION;
    float2 tex : TEXCOORD0;
 };
 
DebugOut ShadowDebugVS (float4 pos : POSITION)
{
    DebugOut OUT;
    
    OUT.pos = float4(0, 0, 0, 1);
    OUT.pos.x = 1 + 0.25 * (rcpres.x/rcpres.y) * (pos.x - 1);
    OUT.pos.y = 1 + 1.0/512.0 + 0.5 * (pos.y - 1);
    OUT.tex = (0.5 + 0.5*shadowRcpRes) + float2(0.5, -0.5) * pos.xy;
    OUT.tex.y *= 2;
    
    return OUT;
}

float4 ShadowDebugPS (DebugOut IN) : COLOR0
{
    float z, red = 0;
    float4 shadowClip, eyeClip;
    
    [branch] if(IN.tex.y < 1)
    {
        // Sample depth
        float2 t = IN.tex;
        z = tex2Dlod(sampDepth, mapShadowToAtlas(t, 0)).r / ESM_scale;
        // Convert pixel position from shadow clip space directly to camera clip space
        shadowClip = float4(2*t.x - 1, 1 - 2*t.y, z, 1);
        eyeClip = mul(shadowClip, vertexblendpalette[0]);
    }
    else
    {
        // Sample depth
        float2 t = IN.tex - float2(0, 1);
        z = tex2Dlod(sampDepth, mapShadowToAtlas(t, 1)).r / ESM_scale;
        // Convert pixel position from shadow clip space directly to camera clip space
        shadowClip = float4(2*t.x - 1, 1 - 2*t.y, z, 1);
        eyeClip = mul(shadowClip, vertexblendpalette[1]);
    }

    // Do perspective divide and mark the pixel if it falls within the camera frustum
    eyeClip.xyz /= eyeClip.w;
    if(abs(eyeClip.x) <= 1 && abs(eyeClip.y) <= 1 && eyeClip.z >= 0 && eyeClip.z <= 1)
        red = saturate(1.5 - eyeClip.w / 8192);
    
    return float4(red, saturate(1-2*z), saturate(2-2*z), 1);
}
