unit raycast_legacy;
{$IFNDEF FPC} {$D-,L-,Y-}{$ENDIF}
{$O+,Q-,R-,S-}
{$IFDEF FPC}{$mode objfpc}{$H+}{$ENDIF}
//   Inspired by Peter Trier http://www.daimi.au.dk/~trier/?page_id=98
//   Philip Rideout http://prideout.net/blog/?p=64
//   and Doyub Kim Jan 2009 http://www.doyub.com/blog/759
//   Ported to Pascal by Chris Rorden Apr 2011
//   Tips for Shaders from
//      http://pages.cs.wisc.edu/~nowak/779/779ClassProject.html#bound
interface
{$include opts.inc}
uses
  {$IFDEF FPC}
    {$IFDEF UNIX} LCLIntf,{$ELSE} Windows, {$ENDIF}
  graphtype,
  {$ELSE}
  Windows,
  {$ENDIF}
  {$IFDEF ENABLEWATERMARK}watermark,{$ENDIF}
{$IFDEF USETRANSFERTEXTURE}texture_3d_unit_transfertexture, {$ELSE} texture_3d_unit,{$ENDIF}
           graphics,
{$IFDEF DGL} dglOpenGL, {$ELSE DGL} {$IFDEF COREGL}glcorearb, {$ELSE} gl,glext, {$ENDIF}  {$ENDIF DGL}
 define_types,
    sysutils, histogram2d, math, raycast_common;

procedure DisplayGLz(var lTex: TTexture; zoom, zoomOffsetX, zoomOffsetY: integer; framebuff: GLUint; isTiled: boolean);
procedure  InitGL (InitialSetup: boolean);// (var lTex: TTexture);
procedure DisplayRender(var lTex: TTexture; lX,lY,lW,lH: single; lOrient: integer);
procedure DisplayGL(var lTex: TTexture);

implementation
uses
  shaderu, mainunit,slices2d;
//this GLSL shader will blur data
const kSmoothShaderFrag = 'uniform float coordZ, dX, dY, dZ;'
+#10'uniform sampler3D intensityVol;'
+#10'void main(void) {'
+#10' vec3 vx = vec3(gl_TexCoord[0].xy, coordZ);'
+#10' vec4 samp = texture3D(intensityVol,vx+vec3(+dX,+dY,+dZ));'
+#10' samp += texture3D(intensityVol,vx+vec3(+dX,+dY,-dZ));'
+#10' samp += texture3D(intensityVol,vx+vec3(+dX,-dY,+dZ));'
+#10' samp += texture3D(intensityVol,vx+vec3(+dX,-dY,-dZ));'
+#10' samp += texture3D(intensityVol,vx+vec3(-dX,+dY,+dZ));'
+#10' samp += texture3D(intensityVol,vx+vec3(-dX,+dY,-dZ));'
+#10' samp += texture3D(intensityVol,vx+vec3(-dX,-dY,+dZ));'
+#10' samp += texture3D(intensityVol,vx+vec3(-dX,-dY,-dZ));'
+#10' gl_FragColor = samp*0.125;'
+#10'}';

//this will estimate a Sobel smooth
const kSobelShaderFrag = 'uniform float coordZ, dX, dY, dZ;'
+#10'uniform sampler3D intensityVol;'
+#10'void main(void) {'
+#10'  vec3 vx = vec3(gl_TexCoord[0].xy, coordZ);'
+#10'  float TAR = texture3D(intensityVol,vx+vec3(+dX,+dY,+dZ)).a;'
+#10'  float TAL = texture3D(intensityVol,vx+vec3(+dX,+dY,-dZ)).a;'
+#10'  float TPR = texture3D(intensityVol,vx+vec3(+dX,-dY,+dZ)).a;'
+#10'  float TPL = texture3D(intensityVol,vx+vec3(+dX,-dY,-dZ)).a;'
+#10'  float BAR = texture3D(intensityVol,vx+vec3(-dX,+dY,+dZ)).a;'
+#10'  float BAL = texture3D(intensityVol,vx+vec3(-dX,+dY,-dZ)).a;'
+#10'  float BPR = texture3D(intensityVol,vx+vec3(-dX,-dY,+dZ)).a;'
+#10'  float BPL = texture3D(intensityVol,vx+vec3(-dX,-dY,-dZ)).a;'
+#10'  vec4 gradientSample = vec4 (0.0, 0.0, 0.0, 0.0);'
+#10'  gradientSample.r =   BAR+BAL+BPR+BPL -TAR-TAL-TPR-TPL;'
+#10'  gradientSample.g =  TPR+TPL+BPR+BPL -TAR-TAL-BAR-BAL;'
+#10'  gradientSample.b =  TAL+TPL+BAL+BPL -TAR-TPR-BAR-BPR;'
+#10'  gradientSample.a = (abs(gradientSample.r)+abs(gradientSample.g)+abs(gradientSample.b))*0.29;'
+#10'  gradientSample.rgb = normalize(gradientSample.rgb);'
+#10'  gradientSample.rgb =  (gradientSample.rgb * 0.5)+0.5;'
+#10'  gl_FragColor = gradientSample;'
+#10'}';
//the gradientSample.a coefficient is critical - 0.25 is technically correct, 0.29 better emulates CPU (where we normalize alpha values in the whole volume)

(*const kMinimalShaderFrag = 'uniform float coordZ, dX, dY, dZ;'
+#10'uniform sampler3D intensityVol;'
+#10'void main(void){'
+#10'  gl_FragColor = vec4 (0.3, 0.5, 0.7, 0.2);'
+#10'}';*)

procedure performBlurSobel(var lTex: TTexture; lIsOverlay: boolean);
//http://www.opengl-tutorial.org/intermediate-tutorials/tutorial-14-render-to-texture/
//http://www.opengl.org/wiki/Framebuffer_Object_Examples
var
   i: integer;
   coordZ: single; //dx
   fb, tempTex3D: GLuint;
begin
  glGenFramebuffersEXT(1, @fb);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fb);
  //glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,gRayCast.frameBuffer);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);// <- REQUIRED
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
  //glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA8, lTex.FiltDim[1], lTex.FiltDim[2], 0, GL_RGBA, GL_UNSIGNED_BYTE, nil);
  glViewport(0, 0, lTex.FiltDim[1], lTex.FiltDim[2]);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  {$IFDEF DGL}
  gluOrtho2D(0, 1, 0, 1);
  {$ELSE}
  glOrtho (0, 1,0, 1, -1, 1);  //gluOrtho2D(0, 1, 0, 1);  https://www.opengl.org/sdk/docs/man2/xhtml/gluOrtho2D.xml
  {$ENDIF}
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity();
  glDisable(GL_TEXTURE_2D);
  glDisable(GL_BLEND);
  //glDisable(GL_TEXTURE_2D);
  //STEP 1: run smooth program gradientTexture -> tempTex3D
  tempTex3D := bindBlankGL(lTex);
  //glUseProgramObjectARB(gRayCast.glslprogramBlur);
  glUseProgram(gRayCast.glslprogramBlur);
  glActiveTexture( GL_TEXTURE1);
  //glBindTexture(GL_TEXTURE_3D, gRayCast.gradientTexture3D);//input texture
  if lIsOverlay then
     glBindTexture(GL_TEXTURE_3D, gRayCast.intensityOverlay3D)//input texture is overlay
  else
      glBindTexture(GL_TEXTURE_3D, gRayCast.intensityTexture3D);//input texture is background
  //glEnable(GL_TEXTURE_2D);
  //glDisable(GL_TEXTURE_2D);
  glUniform1ix(gRayCast.glslprogramBlur, 'intensityVol', 1);
  //glUniform1fx(gRayCast.glslprogramBlur, 'dX', 0.5/lTex.FiltDim[1]); //0.5 for smooth - center contributes
  //glUniform1fx(gRayCast.glslprogramBlur, 'dY', 0.5/lTex.FiltDim[2]);
  //glUniform1fx(gRayCast.glslprogramBlur, 'dZ', 0.5/lTex.FiltDim[3]);
  glUniform1fx(gRayCast.glslprogramBlur, 'dX', 0.7/lTex.FiltDim[1]); //0.5 for smooth - center contributes
  glUniform1fx(gRayCast.glslprogramBlur, 'dY', 0.7/lTex.FiltDim[2]);
  glUniform1fx(gRayCast.glslprogramBlur, 'dZ', 0.7/lTex.FiltDim[3]);
  for i := 0 to (lTex.FiltDim[3]-1) do begin
      coordZ := 1/lTex.FiltDim[3] * (i + 0.5);
      glUniform1fx(gRayCast.glslprogramBlur, 'coordZ', coordZ);
      //glFramebufferTexture3D(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, tempTex3D, 0, i);//output texture
      //Ext required: Delphi compile on Winodws 32-bit XP with NVidia 8400M
      glFramebufferTexture3DExt(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, tempTex3D, 0, i);//output texture
      glClear(GL_DEPTH_BUFFER_BIT);  // clear depth bit (before render every layer)
      glBegin(GL_QUADS);
      glTexCoord2f(0, 0);
      glVertex2f(0, 0);
      glTexCoord2f(1.0, 0);
      glVertex2f(1.0, 0.0);
      glTexCoord2f(1.0, 1.0);
      glVertex2f(1.0, 1.0);
      glTexCoord2f(0, 1.0);
      glVertex2f(0.0, 1.0);
      glEnd();
  end;
  glUseProgram(0);
  //STEP 2: run sobel program gradientTexture -> tempTex3D
  //glUseProgramObjectARB(gRayCast.glslprogramSobel);
  glUseProgram(gRayCast.glslprogramSobel);
  glActiveTexture(GL_TEXTURE1);
  //x glBindTexture(GL_TEXTURE_3D, gRayCast.intensityTexture3D);//input texture
  glBindTexture(GL_TEXTURE_3D, tempTex3D);//input texture
  //  glEnable(GL_TEXTURE_2D);
  //  glDisable(GL_TEXTURE_2D);
    glUniform1ix(gRayCast.glslprogramSobel, 'intensityVol', 1);
    //glUniform1fx(gRayCast.glslprogramSobel, 'dX', 1.0/lTex.FiltDim[1] ); //1.0 for SOBEL - center excluded
    //glUniform1fx(gRayCast.glslprogramSobel, 'dY', 1.0/lTex.FiltDim[2]);
    //glUniform1fx(gRayCast.glslprogramSobel, 'dZ', 1.0/lTex.FiltDim[3]);
    glUniform1fx(gRayCast.glslprogramSobel, 'dX', 1.2/lTex.FiltDim[1] ); //1.0 for SOBEL - center excluded
    glUniform1fx(gRayCast.glslprogramSobel, 'dY', 1.2/lTex.FiltDim[2]);
    glUniform1fx(gRayCast.glslprogramSobel, 'dZ', 1.2/lTex.FiltDim[3]);
    //for i := 0 to (dim3-1) do begin
    //  glColor4f(0.7,0.3,0.2, 0.7);
    for i := 0 to (lTex.FiltDim[3]-1) do begin
        coordZ := 1/lTex.FiltDim[3] * (i + 0.5);
        glUniform1fx(gRayCast.glslprogramSobel, 'coordZ', coordZ);
        (*Ext required: Delphi compile on Winodws 32-bit XP with NVidia 8400M
        if lIsOverlay then
          glFramebufferTexture3D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, gRayCast.gradientOverlay3D, 0, i)
        else
            glFramebufferTexture3D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, gRayCast.gradientTexture3D, 0, i);*)
        if lIsOverlay then
          glFramebufferTexture3DExt(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, gRayCast.gradientOverlay3D, 0, i)//output is overlay
        else
            glFramebufferTexture3DExt(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, gRayCast.gradientTexture3D, 0, i);//output is background
        glClear(GL_DEPTH_BUFFER_BIT);
        glBegin(GL_QUADS);
        glTexCoord2f(0, 0);
        glVertex2f(0, 0);
        glTexCoord2f(1.0, 0);
        glVertex2f(1.0, 0.0);
        glTexCoord2f(1.0, 1.0);
        glVertex2f(1.0, 1.0);
        glTexCoord2f(0, 1.0);
        glVertex2f(0.0, 1.0);
        glEnd();
    end;
    glUseProgram(0);
     //clean up:
     glDeleteTextures(1,@tempTex3D);
     glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
     glDeleteFramebuffersEXT(1, @fb);
     glActiveTexture( GL_TEXTURE0 );  //required if we will draw 2d slices next
end;

(*kPrefilterFrag and performPrefilter() are adapted from the following source and maintain that license
Ruijters & Thévenaz (2012) GPU Prefilter for Accurate Cubic B-spline Interpolation. The Computer Journal. 55, 1: 15-20
https://github.com/DannyRuijters/CubicInterpolationWebGL
Copyright (c) 2008-2014, DannyRuijters
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of CubicInterpolationWebGL nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.*)

const kPrefilterFrag = 'uniform float coordZ;'
+#10'uniform sampler3D uSampler;'
+#10'uniform vec3 increment;'
+#10'void main(void) {'
+#10' vec3 vTextureCoord = vec3(gl_TexCoord[0].xy, coordZ);'
+#10' vec4 w = 1.732176555 * texture3D(uSampler, vTextureCoord);'
+#10' vec3 im = vTextureCoord - increment;'
+#10' vec3 ip = vTextureCoord + increment;'
+#10' w -= 0.464135309 * (texture3D(uSampler,im)+texture3D(uSampler,ip));'
+#10' im -= increment; ip += increment;'
+#10' w += 0.124364681 * (texture3D(uSampler,im)+texture3D(uSampler,ip));'
+#10' im -= increment; ip += increment;'
+#10' w -= 0.033323416 * (texture3D(uSampler,im)+texture3D(uSampler,ip));'
+#10' im -= increment; ip += increment;'
+#10' w += 0.008928982 * (texture3D(uSampler,im)+texture3D(uSampler,ip));'
+#10' im -= increment; ip += increment;'
+#10' w -= 0.002392514 * (texture3D(uSampler,im)+texture3D(uSampler,ip));'
+#10' im -= increment; ip += increment;'
+#10' w += 0.000641072 * (texture3D(uSampler,im)+texture3D(uSampler,ip));'
+#10' im -= increment; ip += increment;'
+#10' w -= 0.000171775 * (texture3D(uSampler,im)+texture3D(uSampler,ip));'
+#10' gl_FragColor = w;'
+#10' //gl_FragColor.r = 1.0; //check it ran'
+#10' }';

procedure performPrefilter(var lTex: TTexture; srcTex: GLuint);
var
   i,passXYZ: integer;
   incX, incY, incZ: single;
   coordZ: single;
   fb, tempTex3Dx, tempTex3Dxy, inTex, outTex: GLuint;
begin
  glGenFramebuffersEXT(1, @fb);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fb);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);// <- REQUIRED
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
  glViewport(0, 0, lTex.FiltDim[1], lTex.FiltDim[2]);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  {$IFDEF DGL}
  gluOrtho2D(0, 1, 0, 1);
  {$ELSE}
  glOrtho (0, 1,0, 1, -1, 1);  //gluOrtho2D(0, 1, 0, 1);  https://www.opengl.org/sdk/docs/man2/xhtml/gluOrtho2D.xml
  {$ENDIF}
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity();
  glDisable(GL_TEXTURE_2D);
  glDisable(GL_BLEND);
  //glDisable(GL_TEXTURE_2D);
  //STEP 1: run smooth program gradientTexture -> tempTex3D
  tempTex3Dx := bindBlankGL(lTex);
  tempTex3Dxy := bindBlankGL(lTex);
  glUseProgram(gRayCast.glslprogramPrefilter);
  glUniform1ix(gRayCast.glslprogramPrefilter, 'uSampler', 1); //input texture will be GL_TEXTURE1
  for passXYZ := 1 to 3 do begin
    //select input texture
    if passXYZ = 1 then begin
       inTex := srcTex; //1st (X): Src -> tempX
       outTex := tempTex3Dx;
       incX:= 1/lTex.FiltDim[1]; incY:=0; incZ:=0;
    end else if (passXYZ = 2) then begin
      inTex := tempTex3Dx; //2nd (Y): tempX -> tempY
      outTex := tempTex3Dxy;
      incX:=0; incY:=1/lTex.FiltDim[2]; incZ:=0;
    end else begin //(passXYZ = 3)
        inTex := tempTex3Dxy; //3rd (Z): tempY -> src
        outTex := srcTex;
        incX:=0; incY:=0; incZ:=1/lTex.FiltDim[3];
    end;
    glActiveTexture( GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_3D, inTex);
    glUniform3f(glGetUniformLocation(gRayCast.GLSLprogram, pAnsiChar('increment')), incX,incY,incZ);
    for i := 0 to (lTex.FiltDim[3]-1) do begin
        coordZ := 1/lTex.FiltDim[3] * (i + 0.5);
        glUniform1fx(gRayCast.glslprogramPrefilter, 'coordZ', coordZ);
        glFramebufferTexture3DExt(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0, GL_TEXTURE_3D, outTex, 0, i);//output texture
        glClear(GL_DEPTH_BUFFER_BIT);  // clear depth bit (before render every layer)
        glBegin(GL_QUADS);
        glTexCoord2f(0, 0);
        glVertex2f(0, 0);
        glTexCoord2f(1.0, 0);
        glVertex2f(1.0, 0.0);
        glTexCoord2f(1.0, 1.0);
        glVertex2f(1.0, 1.0);
        glTexCoord2f(0, 1.0);
        glVertex2f(0.0, 1.0);
        glEnd();
    end;
  end;
  glUseProgram(0);
  //clean up:
  glDeleteTextures(1,@tempTex3Dx);
  glDeleteTextures(1,@tempTex3Dxy);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
  glDeleteFramebuffersEXT(1, @fb);
  glActiveTexture( GL_TEXTURE0 );  //required if we will draw 2d slices next
end; //pre-filter()


procedure doShaderBlurSobel (var lTex: TTexture);
var
   startTime: DWord;
begin
  if (not lTex.updateBackgroundGradientsGLSL) and (not lTex.updateOverlayGradientsGLSL) then exit;
  if (gRayCast.glslprogramPrefilter = 0) then
     gRayCast.glslprogramPrefilter := initVertFrag('',kPrefilterFrag); //initFragShader (kSmoothShaderFrag,gRayCast.glslprogramBlur);
  //crapGL(lTex); exit;
  if (gRayCast.glslprogramBlur = 0) then
     gRayCast.glslprogramBlur := initVertFrag('',kSmoothShaderFrag); //initFragShader (kSmoothShaderFrag,gRayCast.glslprogramBlur);
  if (gRayCast.glslprogramSobel = 0) then
     gRayCast.glslprogramSobel := initVertFrag('',kSobelShaderFrag);
     //initFragShader (kSobelShaderFrag,gRayCast.glslprogramSobel );
    if (lTex.updateBackgroundGradientsGLSL) then begin
       startTime := gettickcount;
       performBlurSobel(lTex, false);
       if (gPrefs.RayCastQuality1to10 = 10) then begin //enable bicubic
          performPrefilter(lTex, gRayCast.intensityTexture3D);
          performPrefilter(lTex, gRayCast.gradientTexture3D);
       end;
       lTex.updateBackgroundGradientsGLSL := false;
       if gPrefs.Debug then
          GLForm1.Caption := 'GLSL gradients '+inttostr(gettickcount-startTime)+' ms ';
    end;
    if (lTex.updateOverlayGradientsGLSL) then begin
       performBlurSobel(lTex, true);
       if (gPrefs.RayCastQuality1to10 = 10) then begin //enable bicubic
          performPrefilter(lTex, gRayCast.intensityOverlay3D);
          performPrefilter(lTex, gRayCast.gradientOverlay3D);
       end;
       lTex.updateOverlayGradientsGLSL := false;
    end;

end;

procedure  enableRenderbuffers;
begin
   glBindFramebufferEXT (GL_FRAMEBUFFER_EXT, gRayCast.frameBuffer);
   glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, gRayCast.renderBuffer);
end;

procedure disableRenderBuffers (framebuff: GLUint);
begin
	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, framebuff);
end;

procedure drawVertex(x,y,z: single);
begin
    	glColor3f(x,y,z);
	glMultiTexCoord3f(GL_TEXTURE1, x, y, z);
	glVertex3f(x,y,z);
end;

procedure drawQuads(x,y,z: single);
//x,y,z typically 1.
// useful for clipping
// If x=0.5 then only left side of texture drawn
// If y=0.5 then only posterior side of texture drawn
// If z=0.5 then only inferior side of texture drawn
begin
	glBegin(GL_QUADS);
	//* Back side
	glNormal3f(0.0, 0.0, -1.0);
	drawVertex(0.0, 0.0, 0.0);
	drawVertex(0.0, y, 0.0);
	drawVertex(x, y, 0.0);
	drawVertex(x, 0.0, 0.0);
	//* Front side
	glNormal3f(0.0, 0.0, 1.0);
	drawVertex(0.0, 0.0, z);
	drawVertex(x, 0.0, z);
	drawVertex(x, y, z);
	drawVertex(0.0, y, z);
	//* Top side
	glNormal3f(0.0, 1.0, 0.0);
	drawVertex(0.0, y, 0.0);
	drawVertex(0.0, y, z);
    drawVertex(x, y, z);
	drawVertex(x, y, 0.0);
	//* Bottom side
	glNormal3f(0.0, -1.0, 0.0);
	drawVertex(0.0, 0.0, 0.0);
	drawVertex(x, 0.0, 0.0);
	drawVertex(x, 0.0, z);
	drawVertex(0.0, 0.0, z);
	//* Left side
	glNormal3f(-1.0, 0.0, 0.0);
	drawVertex(0.0, 0.0, 0.0);
	drawVertex(0.0, 0.0, z);
	drawVertex(0.0, y, z);
	drawVertex(0.0, y, 0.0);
	//* Right side
	glNormal3f(1.0, 0.0, 0.0);
	drawVertex(x, 0.0, 0.0);
	drawVertex(x, y, 0.0);
	drawVertex(x, y, z);
	drawVertex(x, 0.0, z);
	glEnd();
end;

function LoadStr (lFilename: string): string;
var
  myFile : TextFile;
  text : string;
begin
  result := '';
  if not fileexistsEX(lFilename) then begin
    showDebug('Unable to find or open '+lFilename);
    //GLForm1.ShowmessageError('Unable to find '+lFilename);
    exit;
  end;
  FileMode := fmOpenRead;
  AssignFile(myFile,lFilename);
  Reset(myFile);
  while not Eof(myFile) do begin
    ReadLn(myFile, text);
    result := result+text+#13#10;
  end;
  CloseFile(myFile);
end;

procedure reshapeOrtho(w,h: integer);
begin
  if (h = 0) then h := 1;
  glViewport(0, 0,w,h);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  {$IFDEF DGL}
  gluOrtho2D(0, 1, 0, 1.0);
  {$ELSE}
  glOrtho (0, 1,0, 1, -1, 1);  //https://www.opengl.org/sdk/docs/man2/xhtml/gluOrtho2D.xml
  {$ENDIF}
  glMatrixMode(GL_MODELVIEW);//?
end;

{$IFNDEF DGL}  //gl does not link to the glu functions, so we will write our own
procedure gluPerspective (fovy, aspect, zNear, zFar: single);
//https://www.opengl.org/sdk/docs/man2/xhtml/gluPerspective.xml
var
  i, j : integer;
  f: single;
  m : array [0..3, 0..3] of single;
begin
   for i := 0 to 3 do
       for j := 0 to 3 do
           m[i,j] := 0;
   f :=  cot(degtorad(fovy)/2);
   m[0,0] := f/aspect;
   m[1,1] := f;
   m[2,2] := (zFar+zNear)/(zNear-zFar) ;
   m[3,2] := (2*zFar*zNear)/(zNear-zFar);
   m[2,3] := -1;

   //m[2,3] := (2*zFar*zNear)/(zNear-zFar);
   //m[2,2] := -1;

   //glLoadMatrixf(@m[0,0]);
   glMultMatrixf(@m[0,0]);
   //raise an exception if zNear = 0??
end;
{$ENDIF}

procedure resizeGL(w,h, zoom, zoomOffsetX, zoomOffsetY: integer);
var
  whratio,scale: single;
begin
  if (h = 0) then
     h := 1;
  if zoom > 1 then
     glViewport(zoomOffsetX, zoomOffsetY, w*zoom, h*zoom)
  else
      glViewport(0, 0, w, h);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  if gPrefs.Perspective then
    gluPerspective(40.0, w/h, 0.01, kMaxDistance)
  else begin
       if gRayCast.Distance = 0 then
          scale := 1
       else
           scale := 1/abs(kDefaultDistance/(gRayCast.Distance+1.0));
       whratio := w/h;
       glOrtho(whratio*-0.5*scale,whratio*0.5*scale,-0.5*scale,0.5*scale, 0.01, kMaxDistance);
  end;
  glMatrixMode(GL_MODELVIEW);//?
end;

procedure InitGL (InitialSetup: boolean);// (var lTex: TTexture);
begin
  glEnable(GL_CULL_FACE);
  glClearColor(gPrefs.BackColor.rgbRed/255,gPrefs.BackColor.rgbGreen/255,gPrefs.BackColor.rgbBlue/255, 0);
  if (gRayCast.glslprogram <> 0) then begin glDeleteProgram(gRayCast.glslprogram); gRayCast.glslprogram := 0; end;
  gRayCast.glslprogram :=  initVertFrag(gShader.VertexProgram, gShader.FragmentProgram);
  if (gRayCast.glslprogram = 0) then begin //error: load default shader
     LoadShader('', gShader);
     gRayCast.glslprogram :=  initVertFrag(gShader.VertexProgram, gShader.FragmentProgram);
  end;
  getUniformLocations;
  // Create the to FBO's one for the backside of the volumecube and one for the finalimage rendering
  if InitialSetup then begin
    glGenFramebuffersEXT(1, @gRayCast.frameBuffer);
    glGenTextures(1, @gRayCast.backFaceBuffer);
    glGenTextures(1, @gRayCast.finalImage);
    glGenRenderbuffersEXT(1, @gRayCast.renderBuffer);
    gShader.Vendor:= gpuReport;
  end;
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,gRayCast.frameBuffer);
  glBindTexture(GL_TEXTURE_2D, gRayCast.backFaceBuffer);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
  glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA16F_ARB, gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT, 0, GL_RGBA, GL_FLOAT, nil);
  glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, gRayCast.backFaceBuffer, 0);
  glBindTexture(GL_TEXTURE_2D, gRayCast.finalImage);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
  glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA16F_ARB, gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT, 0, GL_RGBA, GL_FLOAT, nil);
  //These next lines moved to DisplayGZz for VirtualBox compatibility
   glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, gRayCast.renderBuffer);
   glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT, gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
  glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, gRayCast.renderBuffer);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
end;

procedure drawUnitQuad;
//stretches image in view space.
begin
	glDisable(GL_DEPTH_TEST);
	glBegin(GL_QUADS);
	glTexCoord2f(0,0);
	glVertex2f(0,0);
	glTexCoord2f(1,0);
	glVertex2f(1,0);
	glTexCoord2f(1, 1);
	glVertex2f(1, 1);
	glTexCoord2f(0, 1);
	glVertex2f(0, 1);
	glEnd();
	glEnable(GL_DEPTH_TEST);
end;

// display the final image on the screen
procedure renderBufferToScreen;
begin
	glClear( GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT );
	glLoadIdentity();
	glEnable(GL_TEXTURE_2D);
	glBindTexture(GL_TEXTURE_2D,gRayCast.finalImage);
	//use next line instead of previous to illustrate one-pass rendering
	//glBindTexture(GL_TEXTURE_2D,backFaceBuffer)
	reshapeOrtho(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
	drawUnitQuad();
	glDisable(GL_TEXTURE_2D);
end;

// render the backface to the offscreen buffer backFaceBuffer
procedure renderBackFace(var lTex: TTexture; var backFace: GLuint);
begin
  glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, backFace, 0);
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT );
  glEnable(GL_CULL_FACE);
  glCullFace(GL_FRONT);
  //glMatrixMode(GL_MODELVIEW);
  //glScalef(lTex.Scale[1],lTex.Scale[2],lTex.Scale[3]);
  drawQuads(1.0,1.0,1.0);
  glDisable(GL_CULL_FACE);
end;

procedure drawFrame(x,y,z: single);
//x,y,z typically 1.
// useful for clipping
// If x=0.5 then only left side of texture drawn
// If y=0.5 then only posterior side of texture drawn
// If z=0.5 then only inferior side of texture drawn
begin
  glColor4f(1,1,1,1);
	glBegin(GL_LINE_STRIP);
	//* Back side
	//glNormal3f(0.0, 0.0, -1.0);
	drawVertex(0.0, 0.0, 0.0);
	drawVertex(0.0, y, 0.0);
	drawVertex(x, y, 0.0);
	drawVertex(x, 0.0, 0.0);
  glEnd;
	glBegin(GL_LINE_STRIP);
	//* Front side
	//glNormal3f(0.0, 0.0, 1.0);
	drawVertex(0.0, 0.0, z);
	drawVertex(x, 0.0, z);
	drawVertex(x, y, z);
	drawVertex(0.0, y, z);
  glEnd;
	glBegin(GL_LINE_STRIP);
	//* Top side
	//glNormal3f(0.0, 1.0, 0.0);
	drawVertex(0.0, y, 0.0);
	drawVertex(0.0, y, z);
    drawVertex(x, y, z);
	drawVertex(x, y, 0.0);
  glEnd;
    glColor4f(0.2,0.2,0.2,0);
	glBegin(GL_LINE_STRIP);
	//* Bottom side
	//glNormal3f(0.0, -1.0, 0.0);
	drawVertex(0.0, 0.0, 0.0);
	drawVertex(x, 0.0, 0.0);
	drawVertex(x, 0.0, z);
	drawVertex(0.0, 0.0, z);
  glEnd;
  glColor4f(0,1,0,0);
	glBegin(GL_LINE_STRIP);
	//* Left side
	//glNormal3f(-1.0, 0.0, 0.0);
	drawVertex(0.0, 0.0, 0.0);
	drawVertex(0.0, 0.0, z);
	drawVertex(0.0, y, z);
	drawVertex(0.0, y, 0.0);
  glEnd;
  glColor4f(1,0,0,0);
  glBegin(GL_LINE_STRIP);
	//* Right side
	//glNormal3f(1.0, 0.0, 0.0);
	drawVertex(x, 0.0, 0.0);
	drawVertex(x, y, 0.0);
	drawVertex(x, y, z);
	drawVertex(x, 0.0, z);
	glEnd();
end;

(* procedure clipMat;
var
  lMgl: array[0..15] of  GLfloat;
begin
glGetFloatv(GL_TRANSPOSE_MODELVIEW_MATRIX, @lMgl);

     clipboard.AsText:= format('m=[%g %g %g %g; %g %g %g %g; %g %g %g %g; %g %g %g %g]',[
       m[0,0], m[0,1], m[0,2], m[0,3],
       m[1,0], m[1,1], m[1,2], m[1,3],
       m[2,0], m[2,1], m[2,2], m[2,3],
       m[3,0], m[3,1], m[3,2], m[3,3]]
       );
end;*)

procedure rayCastingX (var lTex: TTexture; w,h : integer; finalImage, backFaceBuffer: GLuint);
begin
            glUseProgram(gRayCast.glslprogram);
            //glUseProgram(0);
     //glUseProgram(gRayCast.glslprogramGradient);
     glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, finalImage, 0);
	glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT );
	//glEnable(GL_TEXTURE_2D);
        if gShader.SinglePass <> 1 then  begin
           glActiveTexture( GL_TEXTURE0 );
	   glBindTexture(GL_TEXTURE_2D, backFaceBuffer);
           glUniform1i( gRayCast.backFaceLoc, 0 );		// backFaceBuffer -> texture0
           glUniform1f( gRayCast.viewWidthLoc, w );
           glUniform1f( gRayCast.viewHeightLoc, h );
        end;

        glActiveTexture( GL_TEXTURE1 );
	glBindTexture(GL_TEXTURE_3D,gRayCast.gradientTexture3D);
{$IFDEF USETRANSFERTEXTURE}
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_1D, gRayCast.TransferTexture1D);
{$ENDIF}
        glActiveTexture( GL_TEXTURE3 );
	glBindTexture(GL_TEXTURE_3D,gRayCast.intensityTexture3D);
        if  (gShader.OverlayVolume > 0) then begin
          glActiveTexture(GL_TEXTURE4);
          glBindTexture(GL_TEXTURE_3D,gRayCast.intensityOverlay3D);
          if (gShader.OverlayVolume > 1) then begin
             glActiveTexture(GL_TEXTURE5);
             glBindTexture(GL_TEXTURE_3D,gRayCast.gradientOverlay3D);
          end;
        end;
        glUniform1i( gRayCast.LoopsLoc,round(gRayCast.slices*2.2));
        if gRayCast.ScreenCapture then
            glUniform1f( gRayCast.stepSizeLoc, ComputeStepSize(10) )
        else
            glUniform1f( gRayCast.stepSizeLoc, ComputeStepSize(gPrefs.RayCastQuality1to10) );
        glUniform1f( gRayCast.sliceSizeLoc, 1/gRayCast.slices );

        glUniform1i( gRayCast.gradientVolLoc, 1 );	// gradientTexture -> texture2
  {$IFDEF USETRANSFERTEXTURE}
  uniform1i( 'TransferTexture',2); //used when render volumes are scalar, not RGBA{$ENDIF}
  {$ENDIF}
    glUniform1i( gRayCast.intensityVolLoc, 3 );
    glUniform1i( gRayCast.overlayVolLoc, 4 );
    glUniform1i( gRayCast.overlayGradientVolLoc, 5 );
    glUniform1i( gRayCast.overlaysLoc, gOpenOverlays);
  AdjustShaders(gShader);
  LightUniforms;
  ClipUniforms;
  glUniform3f(gRayCast.clearColorLoc,gPrefs.BackColor.rgbRed/255,gPrefs.BackColor.rgbGreen/255,gPrefs.BackColor.rgbBlue/255);
  if gPrefs.RayCastQuality1to10 = 10 then
     glUniform3f(gRayCast.textureSizeLoc, gTexture3D.FiltDim[1], gTexture3D.FiltDim[2], gTexture3D.FiltDim[3]);
  glEnable(GL_CULL_FACE);
  glCullFace(GL_BACK);
  //glMatrixMode(GL_MODELVIEW);
  //glScalef(1,1,1);
  drawQuads(1.0,1.0,1.0);
  glDisable(GL_CULL_FACE);
  glUseProgram(0);
  glActiveTexture( GL_TEXTURE0 );
  //glDisable(GL_TEXTURE_2D);
end;

procedure rayCasting (var lTex: TTexture);
begin
     rayCastingX(lTex,gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT, gRayCast.finalImage, gRayCast.backFaceBuffer);
end;

procedure MakeCube(sz: single);
var
  sz2: single;
begin
  sz2 := sz;
  glColor4f(0.1,0.1,0.1,1);
  glBegin(GL_QUADS);
	//* Bottom side
	glVertex3f(-sz, -sz, -sz2);
	glVertex3f(-sz, sz, -sz2);
	glVertex3f(sz, sz, -sz2);
	glVertex3f(sz, -sz, -sz2);
  glEnd;
  glColor4f(0.8,0.8,0.8,1);
  glBegin(GL_QUADS);
	//* Top side
	glVertex3f(-sz, -sz, sz2);
	glVertex3f(sz, -sz, sz2);
	glVertex3f(sz, sz, sz2);
	glVertex3f(-sz, sz, sz2);
  glEnd;
  glColor4f(0,0,0.4,1);
  glBegin(GL_QUADS);
	//* Front side
	glVertex3f(-sz, sz2, -sz);
	glVertex3f(-sz, sz2, sz);
    glVertex3f(sz, sz2, sz);
	glVertex3f(sz, sz2, -sz);
  glEnd;
  glColor4f(0.2,0,0.2,1);
  glBegin(GL_QUADS);
	//* Back side
	glVertex3f(-sz, -sz2, -sz);
	glVertex3f(sz, -sz2, -sz);
	glVertex3f(sz, -sz2, sz);
	glVertex3f(-sz, -sz2, sz);
  glEnd;
  glColor4f(0.6,0,0,1);
  glBegin(GL_QUADS);
	//* Left side
	glVertex3f(-sz2, -sz, -sz);
	glVertex3f(-sz2, -sz, sz);
	glVertex3f(-sz2, sz, sz);
	glVertex3f(-sz2, sz, -sz);
  glEnd;
  glColor4f(0,0.6,0,1);
  glBegin(GL_QUADS);
	//* Right side
	//glNormal3f(1.0, -sz, -sz);
	glVertex3f(sz2, -sz, -sz);
	glVertex3f(sz2, sz, -sz);
	glVertex3f(sz2, sz, sz);
	glVertex3f(sz2, -sz, sz);
	glEnd();
end;

(*procedure DrawCube (lScrnWid, lScrnHt, zoomOffsetX, zoomOffsetY: integer);
var
  mn: integer;
  sz: single;
begin
  mn := lScrnWid;
  if  mn > lScrnHt then mn := lScrnHt;
  if mn < 10 then exit;
  sz := mn * 0.03;
  // glEnable(GL_CULL_FACE); // <- required for Cocoa
  glDisable(GL_DEPTH_TEST);
  glMatrixMode (GL_PROJECTION);
  glLoadIdentity ();
  glOrtho (0, gRayCast.WINDOW_WIDTH,0, gRayCast.WINDOW_Height,-10*sz,10*sz);
  glEnable(GL_DEPTH_TEST);
  glDisable (GL_LIGHTING);
  glDisable (GL_BLEND);
  glTranslatef(1.8*sz,1.8*sz,0);
  glTranslatef(zoomOffsetX, zoomOffsetY, 0);
  glRotatef(90-gRayCast.Elevation,-1,0,0);
  glRotatef(gRayCast.Azimuth,0,0,1);
  MakeCube(sz);
  //glDisable(GL_DEPTH_TEST);
  //glDisable(GL_CULL_FACE); // <- required for Cocoa
end;   *)

procedure DisplayGLz(var lTex: TTexture; zoom, zoomOffsetX, zoomOffsetY: integer; framebuff: GLUint; isTiled: boolean);
var
   ClrbarSizeFracX: single;
begin
  //if (gPrefs.SliceView  = 5) and (length(gRayCast.MosaicString) < 1) then exit; //we need to draw something, otherwise swapbuffer crashes
  gRayCast.drawFrameBuffer := framebuff;
  if (gPrefs.SliceView  <> 5) then  gRayCast.MosaicString := '';
  doShaderBlurSobel(lTex);
  disableRenderBuffers(framebuff);
  glClearColor(gPrefs.BackColor.rgbRed/255,gPrefs.BackColor.rgbGreen/255,gPrefs.BackColor.rgbBlue/255, 0);
  resizeGL(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT,zoom, zoomOffsetX, zoomOffsetY);
  glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, gRayCast.renderBuffer);
  glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT, gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);  //required by VirtualBox
  {$IFDEF ENABLEMOSAICS}
  if length(gRayCast.MosaicString)> 0 then begin //draw mosaics
     GLForm1.ClearText(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
     glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT );
     glDisable(GL_CULL_FACE); //<-this is important, otherwise nodes and quads not filled
     ClrbarSizeFracX := MosaicGL(gRayCast.MosaicString,lTex);
     //if gPrefs.Colorbar and (gPrefs.SliceView  <> 5) then
     //	DrawCLUT( gPrefs.ColorBarPos,0.01, gPrefs);//, gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoomOffsetX, zoomOffsetY);
    //if gPrefs.Colorbar then
     //  GLForm1.drawClrbar(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoom, zoomOffsetX, zoomOffsetY);
    //GLForm1.DrawText(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoom, zoomOffsetX, zoomOffsetY);
    glEnable (GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    GLForm1.DrawText(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoom, zoomOffsetX, zoomOffsetY);
    reshapeOrtho(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
    if gPrefs.Colorbar then begin
       GLForm1.drawClrbar(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoom, zoomOffsetX, zoomOffsetY, ClrbarSizeFracX);
    end;
  end else {$ENDIF} if gPrefs.SliceView > 0  then begin //draw 2D orthogonal slices
    GLForm1.ClearText(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
    glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT );
    glDisable(GL_CULL_FACE); //<-this is important, otherwise nodes and quads not filled
    DrawOrtho(lTex);
    glEnable (GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    GLForm1.DrawText(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoom, zoomOffsetX, zoomOffsetY);
    reshapeOrtho(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
    if gPrefs.Colorbar then
       GLForm1.drawClrbar(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoom, zoomOffsetX, zoomOffsetY,0);
  end else begin //else draw 3D rendering
    enableRenderbuffers();
    glTranslatef(0,0,-gRayCast.Distance);
    glRotatef(90-gRayCast.Elevation,-1,0,0);
    glRotatef(gRayCast.Azimuth,0,0,1);
    glTranslatef(-lTex.Scale[1]/2,-lTex.Scale[2]/2,-lTex.Scale[3]/2);
    glMatrixMode(GL_MODELVIEW);
    glScalef(lTex.Scale[1],lTex.Scale[2],lTex.Scale[3]);
    if gShader.SinglePass <> 1 then
       renderBackFace(lTex, gRayCast.backFaceBuffer);
    rayCasting(lTex);
    disableRenderBuffers(framebuff);
    renderBufferToScreen();
    if gPrefs.SliceDetailsCubeAndText then
       GLForm1.drawCube(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom,zoom, zoomOffsetX, zoomOffsetY);
    if gPrefs.Colorbar then
       GLForm1.drawClrbar(gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoom, zoomOffsetX, zoomOffsetY,0);
    resizeGL(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT,zoom, zoomOffsetX, zoomOffsetY);
  end;
  if gPrefs.ColorEditor then
    DrawNodes(gRayCast.WINDOW_HEIGHT,gRayCast.WINDOW_WIDTH, lTex, gPrefs);
  //if gPrefs.Colorbar (*and (gPrefs.SliceView  <> 5)*) then
  //  GLForm1.drawClrbar(gRayCast.WINDOW_WIDTH*zoom, zoom, gRayCast.WINDOW_HEIGHT*zoom, zoomOffsetX, zoomOffsetY);

    //DrawCLUT( gPrefs.ColorBarPos,0.01, gPrefs);//, gRayCast.WINDOW_WIDTH*zoom, gRayCast.WINDOW_HEIGHT*zoom, zoomOffsetX, zoomOffsetY);
  {$IFDEF ENABLEWATERMARK}
  if gWatermark.filename <> '' then
    LoadWatermark(gWatermark);
  if gWatermark.Ht > 0 then
    DrawWatermark(gWatermark.X,gWatermark.Y,gWatermark.Wid,gWatermark.Ht,gWatermark);
  {$ENDIF}
  glDisable (GL_BLEND); //just in case one of the previous functions forgot...
  glFlush;//<-this would pause until all jobs are SUBMITTED
  //glFinish;//<-this would pause until all jobs finished: generally a bad idea!
  //next, you will need to execute SwapBuffers
end;

procedure DisplayGL(var lTex: TTexture);
begin
  DisplayGLz(lTex,1,0,0,0, false);
end;

(*procedure resizeGLX(w,h, zoom, zoomOffsetX, zoomOffsetY: integer);
var
  whratio,scale: single;
begin
  if (h = 0) then
     h := 1;
  glViewport(zoomOffsetX, zoomOffsetY, w*zoom, h*zoom);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
       //if gRayCast.Distance = 0 then
          scale := 1;
       //else
       //    scale := 1/abs(kDefaultDistance/(gRayCast.Distance+1.0));
       //whratio := w/h;
       whratio := 1;
      // glOrtho(whratio*-0.5*scale,whratio*0.5*scale,-0.5*scale,0.5*scale, 0.01, kMaxDistance);
      glOrtho(-0.5,0.5,-0.5,0.5, 0.01, kMaxDistance);

      // glOrtho(0, w, 0, h,0.01, kMaxDistance);

  //glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);//<- same effect as previous line

  glMatrixMode(GL_MODELVIEW);//?
end;     *)

(*procedure drawQuad(lX,lY,lW,lH: single);
begin
	glDisable(GL_DEPTH_TEST);
	glBegin(GL_QUADS);
	glTexCoord2f(0,0);
	glVertex2f(lX,lY);
	glTexCoord2f(1,0);
	glVertex2f(lX+lW,lY);
	glTexCoord2f(1, 1);
	glVertex2f(lX+lW, lY+lH);
	glTexCoord2f(0, 1);
	glVertex2f(lX, lY+lH);
	glEnd();
	glEnable(GL_DEPTH_TEST);
end;


procedure reshapeOrthoX(w,h: integer);
begin
  if (h = 0) then h := 1;
  glViewport(0, 0,w,h);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  {$IFDEF DGL}
  gluOrtho2D(0, 1, 0, 1.0);
  //glOrtho2D(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
  {$ELSE}
  //glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
  glOrtho (0, 1,0, 1, -1, 1);  //https://www.opengl.org/sdk/docs/man2/xhtml/gluOrtho2D.xml
  {$ENDIF}
  glMatrixMode(GL_MODELVIEW);//?
end;  *)

(*procedure renderBufferToScreenX(lX,lY,lW,lH: single);
begin
	glLoadIdentity();
	glEnable(GL_TEXTURE_2D);
	glBindTexture(GL_TEXTURE_2D,gRayCast.finalImage);
        if true then begin
	   reshapeOrthoX(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
           drawQuad(lX,lY,1,1);
        end else begin
          glViewport(0, 0,gRayCast.WINDOW_WIDTH,gRayCast.WINDOW_HEIGHT);
          glMatrixMode(GL_PROJECTION);
          glLoadIdentity();

          glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
          glMatrixMode(GL_MODELVIEW);//?
          drawQuad(lX,lY,lW,lh);
	end;
           //glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
	glDisable(GL_TEXTURE_2D);
end;*)

(*Type
TFrameBuffer = record
  backTex, finalTex, renderBuf, depthBuf,frameBuf, tex: GLUint; //we need depth buffer for 2D cube
  w, h: integer;
end;

procedure initFrame (var f : TFrameBuffer);
begin
     f.tex := 0;
     f.depthBuf := 0;
     f.frameBuf := 0;
     f.renderBuf := 0;
     f.backTex := 0;
     f.finalTex := 0;
end;

procedure freeFrame (var f : TFrameBuffer);
begin
  glDeleteTextures(1, @f.tex);
  glDeleteTextures(1, @f.depthBuf);
  glDeleteTextures(1, @f.backTex);
  glDeleteTextures(1, @f.finalTex);

  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
  glDeleteFramebuffersEXT(1, @f.frameBuf);
  glDeleteFramebuffersEXT(1, @f.renderBuf);
  glDeleteRenderbuffersEXT(1,@f.renderBuf);
  //Bind 0, which means render to back buffer, as a result, frameBuf is unbound
end; *)

(*procedure drawBuffers ;
var
  drawBuf: array[0..1] of GLenum;
begin
  drawBuf[0] := GL_COLOR_ATTACHMENT0;
  drawBuf[1] := GL_COLOR_ATTACHMENT1;
  glDrawBuffers(1, @drawBuf[0]); // draw colors only
end;*)
(*function setFrame (wid, ht: integer; var f : TFrameBuffer; isMultiSample: boolean) : boolean; //returns true if multi-sampling
//http://www.opengl-tutorial.org/intermediate-tutorials/tutorial-14-render-to-texture/
var
   w,h: integer;
   drawBuf: array[0..1] of GLenum;
begin
     w := wid;
     h := ht;
     if isMultiSample then begin
        w := w * 2;
        h := h * 2;
     end;
     result := isMultiSample;
     if (w = f.w) and (h = f.h) then begin
         glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, f.frameBuf);
         exit;
     end;
     freeframe(f);
     f.w := w;
     f.h := h;
     //https://www.opengl.org/wiki/Framebuffer_Object_Examples#Quick_example.2C_render_to_texture_.282D.29
     glGenTextures(1, @f.tex);
     glBindTexture(GL_TEXTURE_2D, f.tex);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
     glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA8, f.w, f.h, 0,GL_RGBA, GL_UNSIGNED_BYTE, nil); //RGBA16 for AO
     glGenFramebuffersEXT(1, @f.frameBuf);
     glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, f.frameBuf);
     glDrawBuffer(f.tex);
	glReadBuffer(f.tex);
     //Attach 2D texture to this FBO
     glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, f.tex, 0);
     //
     glBindTexture(GL_TEXTURE_2D, f.backTex);
     glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
     glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA16F_ARB, w, h, 0, GL_RGBA, GL_FLOAT, nil);
     glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, f.backTex, 0);
     //
     glBindTexture(GL_TEXTURE_2D, f.finalTex);
     glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER);
     glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER);
     glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA16F_ARB, f.w, f.h, 0, GL_RGBA, GL_FLOAT, nil);

     //glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, f.tex, 0);
     // Create the depth buffer
    glGenTextures(1, @f.depthBuf);
    glBindTexture(GL_TEXTURE_2D, f.depthBuf);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, f.w, f.h, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, nil);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, f.depthBuf, 0);
     //glDrawBuffers(1, @drawBuf); // "1" is the size of DrawBuffers
     (*drawBuf[0] := GL_COLOR_ATTACHMENT0;
     drawBuf[1] := GL_COLOR_ATTACHMENT1;
     glDrawBuffers(1, @drawBuf[0]); // draw colors only  *)
     glGenRenderbuffersEXT(1, @f.renderBuf);
     glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, f.renderBuf);
     glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT, f.w, f.h);
     glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, f.frameBuf);
     glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, f.renderBuf);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);

     if(glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) <> GL_FRAMEBUFFER_COMPLETE) then begin
       GLForm1.ShowmessageError('Frame buffer error 0x'+inttohex(glCheckFramebufferStatus(GL_FRAMEBUFFER),4) );
       exit;
     end;
end; *)
//// render the backface to the offscreen buffer backFaceBuffer

(*procedure drawQuadX(lX,lY,lW,lH: single);
begin
  //GLform1.Caption := format('%g %g',[lW,lH]);
  glDisable(GL_CULL_FACE); //<-this is important, otherwise nodes and quads not filled
  //glDisable(GL_TEXTURE_2D);
  glDisable(GL_DEPTH_TEST);
	glBegin(GL_QUADS);
        glColor4f(1,0,1,1);
        //glTexCoord2f(0,0);
	glVertex2f(lX,lY);
	//glTexCoord2f(1,0);
	glVertex2f(lX+lW,lY);
	//glTexCoord2f(1, 1);
	glVertex2f(lX+lW, lY+lH/2);
	//glTexCoord2f(0, 1);
	glVertex2f(lX, lY+lH);
	glEnd();
	glEnable(GL_DEPTH_TEST);
end;*)
(*procedure drawQuadX(lX,lY,lW,lH: single);
begin
  //GLform1.Caption := format('%g %g',[lW,lH]);
  //glDisable(GL_CULL_FACE); //<-this is important, otherwise nodes and quads not filled
  glEnable(GL_TEXTURE_2D);
  glDisable(GL_DEPTH_TEST);
	glBegin(GL_QUADS);
        glColor4f(1,0,1,1);
        //glTexCoord2f(0,0);
	glVertex2f(lX,lY);
	//glTexCoord2f(1,0);
	glVertex2f(lX+lW,lY);
	//glTexCoord2f(1, 1);
	glVertex2f(lX+lW, lY+lH/2);
	//glTexCoord2f(0, 1);
	glVertex2f(lX, lY+lH);
	glEnd();
	glEnable(GL_DEPTH_TEST);
end;


procedure renderBufferToScreenXY(lX,lY,lW,lH: single; var f: TFrameBuffer);
begin
	glLoadIdentity();

        glEnable(GL_TEXTURE_2D);
	//glBindTexture(GL_TEXTURE_2D,f.backTex);
        if false then begin
	   reshapeOrthoX(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
           drawQuad(lX,lY,1,1);
        end else begin
          glViewport(0, 0,gRayCast.WINDOW_WIDTH,gRayCast.WINDOW_HEIGHT);
          glMatrixMode(GL_PROJECTION);
          glLoadIdentity();

          glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
          glMatrixMode(GL_MODELVIEW);//?
          drawQuadX(lX,lY,lW,lh);
	end;
           //glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
	glDisable(GL_TEXTURE_2D);
end; *)

(*procedure DisplaySimpleX(var lTex: TTexture;  lX,lY,lW,lH: single);
var
  f: TFrameBuffer;
  w,h: integer;
begin
  initFrame(f);
  disableRenderBuffers(f.frameBuf);

  w := round(lw);
  h := round(lh);
  setFrame (w, h, f, false);

  resizeGLX(w, h,1, 0, 0);
 //resizeGLX(round(lW), round(lH),zoom, zoomOffsetX, zoomOffsetY);

 //resizeGLX(mx, mx,zoom, zoomOffsetX, zoomOffsetY);
 glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
 //glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, f.frameBuf); //<- required for 2D views
 //glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, f.renderBuf);
 //glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT, w, h);
//glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, f.renderBuf);

 //glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, f.renderBuf);
 //glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT, w, h);  //required by VirtualBox

 //enableRenderbuffers();
   glTranslatef(0,0,-0.5);

   glTranslatef(-lTex.Scale[1]/2,-lTex.Scale[2]/2,-lTex.Scale[3]/2);
   glMatrixMode(GL_MODELVIEW);
   glScalef(lTex.Scale[1],lTex.Scale[2],lTex.Scale[3]);
   renderBackFace(lTex, f.backTex);
   rayCastingX (lTex, w,h,f.finalTex, f.backTex);
   glFlush;
   glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);

   renderBufferToScreenXY(lX,lY,128,128, f);


   freeFrame(f);

end;*)
(*procedure drawBox;
begin
glBegin(GL_QUADS);
glTexCoord2f(0, 0);
glVertex2f(0, 0);
glTexCoord2f(1.0, 0);
glVertex2f(1.0, 0.0);
glTexCoord2f(1.0, 1.0);
glVertex2f(1.0, 1.0);
glTexCoord2f(0, 1.0);
glVertex2f(0.0, 1.0);
glEnd();
end;*)

(*
procedure DisplaySimpleXX(var lTex: TTexture;  lX,lY,lW,lH: single);
var
  f: TFrameBuffer;
  w,h: integer;
begin
  initFrame(f);
  disableRenderBuffers(f.frameBuf);

  //w := gRayCast.WINDOW_WIDTH ;
  //h := gRayCast.WINDOW_HEIGHT;
  w := round(lw);
  h := round(lh);
  setFrame (w, h, f, false);
  glBindFramebufferEXT (GL_FRAMEBUFFER_EXT, f.frameBuf);
  glViewport(0,0,w,h);
  glBindTexture(GL_TEXTURE_2D, 0);
  glEnable(GL_TEXTURE_2D);
  resizeGLX(w, h,1, 0, 0);
 //resizeGLX(round(lW), round(lH),zoom, zoomOffsetX, zoomOffsetY);

 //resizeGLX(mx, mx,zoom, zoomOffsetX, zoomOffsetY);
 //glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);

 //glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, f.renderBuf);
 //glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT, w, h);  //required by VirtualBox

 //glViewport(0,0,w,h);


 glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, f.renderBuf);
 //glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, f.frameBuf); //<- required for 2D views
 //glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, f.renderBuf);
 //glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT, w, h);
//glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, f.renderBuf);
  //glBindFramebufferEXT (GL_FRAMEBUFFER_EXT, 0);
   glBindTexture(GL_TEXTURE_2D, f.backTex);

glClearColor(1,0,0.5, 0.5);

glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT );

 //enableRenderbuffers();
   glTranslatef(0,0,-0.5);

   glTranslatef(-lTex.Scale[1]/2,-lTex.Scale[2]/2,-lTex.Scale[3]/2);
   glMatrixMode(GL_MODELVIEW);
   glScalef(lTex.Scale[1],lTex.Scale[2],lTex.Scale[3]);
   glUseProgram(0);
   //renderBackFace(lTex, f.backTex);
   renderBackFace(lTex, f.tex);

   //rayCastingX (lTex, w,h,f.finalTex, f.backTex);
   glFlush;
   //glBindTexture(GL_TEXTURE_2D, f.backTex);
   //glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
   glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
   //drawBuffers;
   glClearColor(1,1,1, 0.5);
   glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);


   //glViewport(0,0,w,h);
   glBindTexture(GL_TEXTURE_2D, f.tex);

        glDisable(GL_CULL_FACE); //<-this is important, otherwise nodes and quads not filled
    glEnable (GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);


   //glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
 //  glBindFramebufferEXT(GL_READ_FRAMEBUFFER,f.frameBuf);
 // bind the source framebuffer and select a color attachment to copy from
 //glReadBuffers(GL_COLOR_ATTACHMENT0);

// bind the destination framebuffer and select the color attachments to copy to

//GLuint attachments[2] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1 };
//glDrawBuffers(2, attachments);

// copy
//glBlitFramebuffer(0,0,W, H, 0,0,512,512, GL_COLOR_BUFFER_BIT, GL_LINEAR);

   //renderBufferToScreenXY(lX,lY,128,128, f);
   //glEnable (GL_BLEND);
   glUseProgram(0);
   renderBufferToScreenXY(lX,lY,lW,lH, f);

   glDisable(GL_TEXTURE_2D);
   freeFrame(f);

end;*)



(*procedure DisplaySimpleX2(var lTex: TTexture;  lX,lY,lW,lH: single);
var
  framebuff: GLUint = 0;
  zoom: integer;
  f: TFrameBuffer;
  zoomOffsetX, zoomOffsetY: integer;
  w,h: integer;
begin
  initFrame(f);
  setFrame (round(lw), round(lh), f, false);

  zoom := 1;
  zoomOffsetX := 0;
  zoomOffsetY := 0;
  //w := gRayCast.WINDOW_WIDTH div 2;
  //h := gRayCast.WINDOW_HEIGHT div 2;

  w := round(lw);
  h := round(lh);
//  GLForm1.Caption := format('%d %d',[w,h]);
 resizeGLX(w, h,zoom, zoomOffsetX, zoomOffsetY);

 //resizeGLX(round(lW), round(lH),zoom, zoomOffsetX, zoomOffsetY);

 //resizeGLX(mx, mx,zoom, zoomOffsetX, zoomOffsetY);

 enableRenderbuffers();
   glTranslatef(0,0,-0.5);
   //glTranslatef(0,0,-gRayCast.Distance);
   //glRotatef(90,-1,0,0);
   //glRotatef(0,0,0,1);

   //glTranslatef(0,0,-gRayCast.Distance);
   //glRotatef(90-gRayCast.Elevation,-1,0,0);
   //glRotatef(gRayCast.Azimuth,0,0,1);
   glTranslatef(-lTex.Scale[1]/2,-lTex.Scale[2]/2,-lTex.Scale[3]/2);
   glMatrixMode(GL_MODELVIEW);
   glScalef(lTex.Scale[1],lTex.Scale[2],lTex.Scale[3]);
   if gShader.SinglePass <> 1 then
      renderBackFace(lTex, gRayCast.backFaceBuffer);
   rayCasting(lTex);
   glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, framebuff);
   // disableRenderBuffers(framebuff);

   //,lY,lW,lH

   renderBufferToScreenX(lX,lY,128,128);
   freeFrame(f);

end;*)

(*procedure renderBufferToScreenXX(lX,lY,lW,lH: single);
begin
	glLoadIdentity();
	glEnable(GL_TEXTURE_2D);
	glBindTexture(GL_TEXTURE_2D,gRayCast.finalImage);
        if false then begin
	   reshapeOrthoX(gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT);
           drawQuad(lX,lY,1,1);
        end else begin
          glViewport(0, 0,gRayCast.WINDOW_WIDTH,gRayCast.WINDOW_HEIGHT);
          glMatrixMode(GL_PROJECTION);
          glLoadIdentity();

          glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
          glMatrixMode(GL_MODELVIEW);//?
          drawQuad(lX,lY,lW,lh);
	end;
           //glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
	glDisable(GL_TEXTURE_2D);
end;


procedure DisplaySimpleXWorks(var lTex: TTexture;  lX,lY,lW,lH: single);
var
  framebuff: GLUint = 0;
  zoom: integer;
  f: TFrameBuffer;
  zoomOffsetX, zoomOffsetY: integer;
  w,h: integer;
begin
  initFrame(f);
  setFrame (round(lw), round(lh), f, false);

  zoom := 1;
  zoomOffsetX := 0;
  zoomOffsetY := 0;

  w := round(lw);
  h := round(lh);
 resizeGLX(w, h,zoom, zoomOffsetX, zoomOffsetY);
 enableRenderbuffers();
   glTranslatef(0,0,-0.5);
   //glTranslatef(0,0,-gRayCast.Distance);
   //glRotatef(90,-1,0,0);
   //glRotatef(0,0,0,1);

   //glTranslatef(0,0,-gRayCast.Distance);
   //glRotatef(90-gRayCast.Elevation,-1,0,0);
   //glRotatef(gRayCast.Azimuth,0,0,1);
   glTranslatef(-lTex.Scale[1]/2,-lTex.Scale[2]/2,-lTex.Scale[3]/2);
   glMatrixMode(GL_MODELVIEW);
   glScalef(lTex.Scale[1],lTex.Scale[2],lTex.Scale[3]);
   if gShader.SinglePass <> 1 then
      renderBackFace(lTex, gRayCast.backFaceBuffer);
   //rayCasting(lTex);
   rayCastingX(lTex,gRayCast.WINDOW_WIDTH, gRayCast.WINDOW_HEIGHT, gRayCast.finalImage, gRayCast.backFaceBuffer);
   glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, framebuff);
   // disableRenderBuffers(framebuff);

   renderBufferToScreenXX(lX,lY,lW,lH);
   freeFrame(f);

end;    *)


procedure resizeDepth(d: integer);
begin
  glViewport(0, 0,gRayCast.WINDOW_WIDTH,gRayCast.WINDOW_HEIGHT);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();

  //glOrtho(0,30,0,30, 0.001, d);
  //glOrtho(0,gRayCast.WINDOW_WIDTH,0,gRayCast.WINDOW_HEIGHT, 0.001, d);
  glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,0.001,d);//<- same effect as previous line

  glMatrixMode(GL_MODELVIEW);//?
end;

procedure drawQuadD(lX,lY,lW,lH, lXf, lYf: single);
begin
	glDisable(GL_DEPTH_TEST);
	glBegin(GL_QUADS);
	glTexCoord2f(0,0);
	glVertex2f(lX,lY);
	glTexCoord2f(lXf,0);
	glVertex2f(lX+lW,lY);
	glTexCoord2f(lXf, lYf);
	glVertex2f(lX+lW, lY+lH);
	glTexCoord2f(0, lYf);
	glVertex2f(lX, lY+lH);
	glEnd();
	glEnable(GL_DEPTH_TEST);
end;


procedure renderBufferToScreenD(lX,lY,lW,lH, lXf, lYf: single);
begin
	glLoadIdentity();
	glEnable(GL_TEXTURE_2D);
	glBindTexture(GL_TEXTURE_2D,gRayCast.finalImage);

        glViewport(0, 0,gRayCast.WINDOW_WIDTH,gRayCast.WINDOW_HEIGHT);
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();

        glOrtho(0, gRayCast.WINDOW_WIDTH, 0, gRayCast.WINDOW_HEIGHT,-1,1);
        glMatrixMode(GL_MODELVIEW);//?
        drawQuadD(lX,lY,lW,lh, lXf, lYf );
	glDisable(GL_TEXTURE_2D);
end;


procedure DisplayRenderCore(var lTex: TTexture;  lX,lY,lW,lH: single; lOrient: integer);
var
  w,h,d: integer;
  lXf, lYf: single;
begin
  w := round(lw);
  h := round(lh);
  lXf := w/gRayCast.WINDOW_WIDTH;
  lYf := h/gRayCast.WINDOW_HEIGHT;
  //if axial:
  if abs(lOrient) = kAxialOrient then
     d := round(lw * lTex.Scale[3]/lTex.Scale[1]) //depth z, width is x
  else if abs(lOrient) = kCoronalOrient then
       d := round(lw * lTex.Scale[2]/lTex.Scale[1]) //depth y, width is X
  else if (lOrient = kSagRightOrient) or (lOrient = kSagLeftOrient) then
       d := round(lw * lTex.Scale[1]/lTex.Scale[2]) //depth x , width is Y
  else
      exit;
  resizeDepth(d*3);
  enableRenderbuffers();

  glTranslatef(0,0,-d * 1.5);

  if (lOrient = kSagRightOrient) then begin
     (*glScalef(w,h,d/2);
     glTranslatef(w,0,0);

     glRotatef(90,-1,0,0);
     glRotatef(90,0,0,1);*)

     glTranslatef(w,0,0);
           glScalef(w,h,d);
      glRotatef(90,-1,0,0);
      glRotatef(90,0,0,1);

  end;
  if (lOrient = kSagLeftOrient) then begin
      //glTranslatef(w,0,0);
      glScalef(w,h,d);
      glRotatef(90,-1,0,0);
      glRotatef(270,0,0,1);
   end;
   if lOrient = kCoronalOrient then begin
      //glRotatef(10,1,0,0); //coronal: back of head
      //glTranslatef(0,0,0.1*d);
      glTranslatef(w,0,0);
      glScalef(w,h,d);
      glRotatef(90,-1,0,0);
      glRotatef(180,0,0,1);
   end;
   if lOrient = -kCoronalOrient then begin
      glScalef(w,h,d);
      glRotatef(90,-1,0,0); //coronal: back of head
   end;

   //glRotatef(90,-1,0,0); //coronal: back of head
   //axial Back:
   if lOrient = -kAxialOrient then begin
      glTranslatef(w,0,0);
      glRotatef(180,0,1,0); //coronal
   end;
   //glRotatef(gRayCast.Azimuth,0,0,1);




   //glTranslatef(-k,-k,-k);


   //glTranslatef(0,0,-gRayCast.Distance);
   //glRotatef(90,-1,0,0);
   //glRotatef(0,0,0,1);

   //glTranslatef(0,0,-gRayCast.Distance);
   //glRotatef(90-gRayCast.Elevation,-1,0,0);
   //glRotatef(gRayCast.Azimuth,0,0,1);

   //glTranslatef(-lTex.Scale[1]/2,-lTex.Scale[2]/2,-lTex.Scale[3]/2);

   //glTranslatef(0,0,-lTex.Scale[3]/2);


    //glTranslatef(0,0,-1.5* d);

   //glRotatef(90,0,0,1);
   //glTranslatef(-1,-1,-lTex.Scale[3]/2);
   glMatrixMode(GL_MODELVIEW);
   (*if abs(lOrient) = kAxialOrient then
      d := round(lw * lTex.Scale[3]/lTex.Scale[1]) //depth z, width is x
   else if abs(lOrient) = kCoronalOrient then
        d := round(lw * lTex.Scale[2]/lTex.Scale[1]) //depth y, width is X
   else //if (lOrient = kSagRightOrient) or (lOrient = kSagLeftOrient) then
        d := round(lw * lTex.Scale[1]/lTex.Scale[2]) //depth x , width is Y
   else
       exit;
                     *)
   //glScalef(w,h,d/2);
   if abs(lOrient) = kAxialOrient then
      glScalef(w,h,d/2);

   if gShader.SinglePass <> 1 then
      renderBackFace(lTex, gRayCast.backFaceBuffer);
   rayCasting(lTex);
   glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
   disableRenderBuffers(gRayCast.drawFrameBuffer);
   renderBufferToScreenD(lX,lY,lW,lH, lXf, lYf);
end;



procedure DisplayRender(var lTex: TTexture; lX,lY,lW,lH: single; lOrient: integer);
begin
  glDisable (GL_TEXTURE_3D);
  //glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glEnable(GL_CULL_FACE); //<-this is important, otherwise nodes and quads not filled
  //glDisable (GL_BLEND);
  doShaderBlurSobel(lTex);
  disableRenderBuffers(gRayCast.drawFrameBuffer);
  //glClearColor(gPrefs.BackColor.rgbRed/255,gPrefs.BackColor.rgbGreen/255,gPrefs.BackColor.rgbBlue/255, 0);
  DisplayRenderCore(lTex,lX,lY,lW,lH, lOrient);
  //   glFlush;
  glDisable (GL_BLEND); //just in case one of the previous functions forgot...
  glEnable (GL_TEXTURE_3D);
end;

end.

