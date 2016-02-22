unit nii_reslice;
interface
//{$D-,O+,Q-,R-,S-} // L-,Y-,
{$H+}
{$IFDEF FPC}{$mode delphi}{$ENDIF}
uses
  Dialogs, nii_mat,define_types,sysutils,prefs,nifti_hdr,Texture_3D_Unit, nifti_types;

//function Reslice2Targ (lSrcName,lTargetName,lDestName: string; lPrefs: TPrefs):string;
procedure NIFTIhdr_UnswapImg (var lHdr: TMRIcroHdr; var lImgBuffer: byteP); //ensures image data is in native space
procedure NIFTIhdr_MinMaxImg (var lHdr: TMRIcroHdr; var lImgBuffer: byteP); //ensures image data is in native space
procedure Int32ToFloat (var lHdr: TMRIcroHdr; var lImgBuffer: byteP);
procedure Float32RemoveNAN (var lHdr: TMRIcroHdr; var lImgBuffer: byteP);

function Reslice2Targ (lSrcName: string; var lTargHdr: TNIFTIHdr; var lDestHdr: TMRIcroHdr; lTrilinearInterpolation: boolean; lVolume: integer): string;
function Reslice2TargCore (var lSrcHdr: TMRIcroHdr; var lSrcBuffer: bytep;  var lTargHdr: TNIFTIHdr; var lDestHdr: TMRIcroHdr; lTrilinearInterpolation: boolean; lVolume: integer): string;

implementation

function Hdr2Mat (lHdr:  TNIFTIhdr): TMatrix;
begin
  Result := Matrix3D (
  lHdr.srow_x[0],lHdr.srow_x[1],lHdr.srow_x[2],lHdr.srow_x[3],
  lHdr.srow_y[0],lHdr.srow_y[1],lHdr.srow_y[2],lHdr.srow_y[3],
  lHdr.srow_z[0],lHdr.srow_z[1],lHdr.srow_z[2],lHdr.srow_z[3]);
end;

procedure  Coord(var lV: TVector; var lMat: TMatrix);
//transform X Y Z by matrix
var
  lXi,lYi,lZi: single;
begin
  lXi := lV.vector[1]; lYi := lV.vector[2]; lZi := lV.vector[3];
  lV.vector[1] := (lXi*lMat.matrix[1][1]+lYi*lMat.matrix[1][2]+lZi*lMat.matrix[1][3]+lMat.matrix[1][4]);
  lV.vector[2] := (lXi*lMat.matrix[2][1]+lYi*lMat.matrix[2][2]+lZi*lMat.matrix[2][3]+lMat.matrix[2][4]);
  lV.vector[3] := (lXi*lMat.matrix[3][1]+lYi*lMat.matrix[3][2]+lZi*lMat.matrix[3][3]+lMat.matrix[3][4]);
end;

procedure SubVec (var lVx: TVector; lV0: TVector);
begin
  lVx.vector[1] := lVx.vector[1] - lV0.vector[1];
  lVx.vector[2] := lVx.vector[2] - lV0.vector[2];
  lVx.vector[3] := lVx.vector[3] - lV0.vector[3];
end;



function Voxel2Voxel (var lDestHdr,lSrcHdr: TNIFTIhdr): TMatrix;
//returns matrix for transforming voxels from one image to the other image
//results are in VOXELS not mm
var
   lV0,lVx,lVy,lVz: TVector;
   lDestMat,lSrcMatInv,lSrcMat: TMatrix;

begin
     //Step 1 - compute source coordinates in mm for 4 voxels
     //the first vector is at 0,0,0, with the
     //subsequent voxels being left, up or anterior
     lDestMat := Hdr2Mat(lDestHdr);
     //SPMmat(lDestMat);
     lV0 := vec3D  ( 0,0,0);
     lVx := vec3D  ( 1,0,0);
     lVy := vec3D  ( 0,1,0);
     lVz := vec3D  ( 0,0,1);
     Coord(lV0,lDestMat);
     Coord(lVx,lDestMat);
     Coord(lVy,lDestMat);
     Coord(lVz,lDestMat);
     lSrcMat := Hdr2Mat(lSrcHdr);
     //SPMmat(lSrcMat);
     lSrcMatInv := lSrcMat;
     invertMatrix(lSrcMatInv);
     //the vectors should be rows not columns....
     //therefore we transpose the matrix
     transposeMatrix(lSrcMatInv);
     //the 'transform' multiplies the vector by the matrix
     lV0 := Transform3D (lV0,lSrcMatInv);
     lVx := Transform3D (lVx,lSrcMatInv);
     lVy := Transform3D (lVy,lSrcMatInv);
     lVz := Transform3D (lVz,lSrcMatInv);
     //subtract each vector from the origin
     // this reveals the voxel-space influence for each dimension
     SubVec(lVx,lV0);
     SubVec(lVy,lV0);
     SubVec(lVz,lV0);
     result := Matrix3D(lVx.vector[1],lVy.vector[1],lVz.vector[1],lV0.vector[1],
      lVx.vector[2],lVy.vector[2],lVz.vector[2],lV0.vector[2],
      lVx.vector[3],lVy.vector[3],lVz.vector[3],lV0.vector[3]);
end;

procedure CopyHdrMat(var lTarg,lDest: TNIfTIHdr);
//destination has dimensions and rotations of destination
var
   lI: integer;
begin
     //destination will have dimensions of target
   lDest.dim[0] := 3; //3D
   for lI := 1 to 3 do
       lDest.dim[lI] := lTarg.dim[lI];
   lDest.dim[4] := 1; //3D
   //destination will have pixdim of target
   for lI := 0 to 7 do
       lDest.pixdim[lI] := lTarg.pixdim[lI];
   lDest.xyzt_units := lTarg.xyzt_units; //e.g. mm and sec
   lDest.qform_code := lTarg.qform_code;
   lDest.sform_code := lTarg.sform_code;
   lDest.quatern_b := lTarg.quatern_b;
   lDest.quatern_c := lTarg.quatern_c;
   lDest.quatern_d := lTarg.quatern_d;
   lDest.qoffset_x := lTarg.qoffset_x;
   lDest.qoffset_y := lTarg.qoffset_y;
   lDest.qoffset_z := lTarg.qoffset_z;
   for lI := 0 to 3 do begin
       lDest.srow_x[lI] := lTarg.srow_x[lI];
       lDest.srow_y[lI] := lTarg.srow_y[lI];
       lDest.srow_z[lI] := lTarg.srow_z[lI];
   end;
end;

procedure NIFTIhdr_UnswapImg (var lHdr: TMRIcroHdr; var lImgBuffer: byteP); //ensures image data is in native space
//returns data in native endian
//sets 'ByteSwap' flag to false. E.G. a big-endian image will be saved as little-endian on little endian machines
var
   lInc,lImgSamples : integer;
   l32f : SingleP;
   //l32i : LongIntP;
   l16i : SmallIntP;
begin
     if lHdr.DiskDataNativeEndian then exit;
     case lHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : begin
              exit;
            end;
	  kDT_SIGNED_SHORT,kDT_SIGNED_INT,kDT_FLOAT: ;//supported format
         else begin
             Msg('niftiutil UnSwapImg error: datatype not supported.');
             exit;
         end;
     end; //case
     lImgSamples := lHdr.NIFTIhdr.Dim[1] *lHdr.NIFTIhdr.Dim[2]*lHdr.NIFTIhdr.Dim[3];
     if lImgSamples < 1 then
        exit;
     case lHdr.NIFTIhdr.datatype of
	  kDT_SIGNED_SHORT: begin
             l16i := SmallIntP(@lImgBuffer^);
             for lInc := 1 to lImgSamples do
                 l16i^[lInc] := Swap(l16i^[lInc]);
          end; //l16i
          kDT_SIGNED_INT,kDT_FLOAT: begin
             l32f := SingleP(lImgBuffer );
              for lInc := 1 to lImgSamples do
                pswap4r(l32f^[lInc]);
             //note: for the purposes of byte swapping, floats and long ints are the same
             (*l32i := LongIntP(@lImgBuffer^);
             for lInc := 1 to lImgSamples do
                 l32i^[lInc] := (Swap4r4i(l32i^[lInc])) *)
          end;//32i
     end; //case
     lHdr.DiskDataNativeEndian := true;
end;

procedure NIFTIhdr_MinMaxImg (var lHdr: TMRIcroHdr; var lImgBuffer: byteP); //ensures image data is in native space
//Sets lHdr.GlMinUnscaledS and lHdr.GlMaxUnscaledS - worth doing when image is loaded....
var
   lInc,lImgSamples, lMini,lMaxi : integer;
   lMaxS,lMinS: single;
   l32i : LongIntP;
   l32f: SingleP;
   l16Buf : SmallIntP;
begin

(*     if lHdr.DiskDataNativeEndian then exit;
     case lHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : begin
              exit;
            end;
	  kDT_SIGNED_SHORT,kDT_SIGNED_INT,kDT_FLOAT: ;//supported format
         else begin
             Msg('niftiutil UnSwapImg error: datatype not supported.');
             exit;
         end;
     end; //case *)
     lImgSamples := lHdr.NIFTIhdr.Dim[1] *lHdr.NIFTIhdr.Dim[2]*lHdr.NIFTIhdr.Dim[3];
     if lImgSamples < 1 then
        exit;
     case lHdr.NIFTIhdr.datatype of
	  kDT_UNSIGNED_CHAR: begin
      lMini := lImgBuffer^[1];
      lMaxi := lImgBuffer^[1];
	    for lInc := 1 to lImgSamples do begin
        if lImgBuffer^[lInc] >  lMaxi then
          lMaxi := lImgBuffer^[lInc];
        if lImgBuffer^[lInc] <  lMini then
          lMini := lImgBuffer^[lInc];
      end;
       lHdr.GlMinUnscaledS := lMini;
       lHdr.GlMaxUnscaledS := lMaxi;
    end; //l16i
	  kDT_SIGNED_SHORT: begin
	    l16Buf := SmallIntP(lImgBuffer {lHdr.ImgBuffer} );
      lMini := l16Buf^[1];
      lMaxi := l16Buf^[1];
	    for lInc := 1 to lImgSamples do begin
        if l16Buf^[lInc] >  lMaxi then
          lMaxi := l16Buf^[lInc];
        if l16Buf^[lInc] <  lMini then
          lMini := l16Buf^[lInc];
      end;
       lHdr.GlMinUnscaledS := lMini;
       lHdr.GlMaxUnscaledS := lMaxi;
    end; //l16i
      kDT_SIGNED_INT: begin
             l32i := LongIntP(@lImgBuffer^);
      lMini := l32i^[1];
      lMaxi := l32i^[1];
	    for lInc := 1 to lImgSamples do begin
        if l32i^[lInc] >  lMaxi then
          lMaxi := l32i^[lInc];
        if l32i^[lInc] <  lMini then
          lMini := l32i^[lInc];
      end;
       lHdr.GlMinUnscaledS := lMini;
       lHdr.GlMaxUnscaledS := lMaxi;

      end; //32i
      kDT_FLOAT: begin
             l32f := SingleP(@lImgBuffer^);
      lMins := l32f^[1];
      lMaxs := l32f^[1];
	    for lInc := 1 to lImgSamples do begin
        if l32f^[lInc] >  lMaxs then
          lMaxs := l32f^[lInc];
        if l32f^[lInc] <  lMins then
          lMins := l32f^[lInc];
      end;
       lHdr.GlMinUnscaledS := lMins;
       lHdr.GlMaxUnscaledS := lMaxs;
          end;//32i
     end; //case
end;

(*procedure Float64ToFloat32 (var lHdr: TMRIcroHdr; var lImgBuffer: byteP);
var
  lI,lInVox: integer;
  l64Buf : DoubleP;
  lV: double;
  l32TempBuf,l32Buf : SingleP;
begin
	  if lHdr.NIFTIHdr.datatype <> kDT_DOUBLE then
      exit;
    lInVox :=  lHdr.NIFTIhdr.dim[1] *  lHdr.NIFTIhdr.dim[2] * lHdr.NIFTIhdr.dim[3];
    l64Buf := DoubleP(lImgBuffer );
    GetMem(l32TempBuf ,lInVox*sizeof(single));  *)


function RGB24ToByte (var lHdr: TMRIcroHdr; var lImgBuffer: byteP; lVolume: integer): boolean;//RGB
//red green blue saved as contiguous planes...
var
  lInSlice,lOutSlice,lZ,lSliceSz,lSliceVox: integer;
  lP: bytep;
begin
    result := false;
        if lHdr.NIFTIHdr.datatype <> kDT_RGB then
      exit;
    lSliceSz := lHdr.NIFTIhdr.Dim[1]*lHdr.NIFTIhdr.Dim[2];
    lZ := lSliceSz * 3 * lHdr.NIFTIhdr.Dim[3];
    if lZ < 1 then exit;
    getmem( lP,lZ);
    Move(lImgBuffer^,lP^,lZ);
    freemem(lImgBuffer);
    lZ := lSliceSz  * lHdr.NIFTIhdr.Dim[3];
    GetMem(lImgBuffer,lZ);
    if (lVolume mod 3) = 1 then //green
      lInSlice := lSliceSz
    else if (lVolume mod 3) = 2 then//blue
      lInSlice := lSliceSz+lSliceSz
    else
      lInSlice := 0;
    lOutSlice := 0;
    for lZ := 1 to lHdr.NIFTIhdr.Dim[3] do begin
      for lSliceVox := 1 to lSliceSz do
        lImgBuffer^[lSliceVox+lOutSlice] := lP^[lSliceVox+lInSlice];
      inc(lOutSlice,lSliceSz);
      inc(lInSlice,lSliceSz+lSliceSz+lSliceSz);
    end;
    freemem(lP);
    (*for lZ := 0 to 255 do begin
			lHdr.LUT[lZ].rgbRed := 0;
			lHdr.LUT[lZ].rgbGreen := 0;
			lHdr.LUT[lZ].rgbBlue := 0;
			lHdr.LUT[lZ].rgbReserved := kLUTalpha;
		end;
    if (lVolume mod 3) = 1 then begin//green
      for lZ := 0 to 255 do
			  lHdr.LUT[lZ].rgbGreen := lZ;
    end else if (lVolume mod 3) = 2 then begin //blue
      for lZ := 0 to 255 do
			  lHdr.LUT[lZ].rgbBlue := lZ;
    end else begin
      for lZ := 0 to 255 do
			  lHdr.LUT[lZ].rgbRed := lZ;
    end;     *)
    lHdr.NIFTIhdr.datatype := kDT_UNSIGNED_CHAR;
    lHdr.RGB := true;
    lHdr.NIFTIhdr.scl_slope := 1.0;
    lHdr.NIFTIhdr.scl_inter:= 0.0;
    result := true;
end;

procedure Int32ToFloat (var lHdr: TMRIcroHdr; var lImgBuffer: byteP);
var
  lI,lInVox: integer;
  l32Buf : SingleP;
begin
	  if lHdr.NIFTIHdr.datatype <> kDT_SIGNED_INT then
      exit;
    lInVox :=  lHdr.NIFTIhdr.dim[1] *  lHdr.NIFTIhdr.dim[2] * lHdr.NIFTIhdr.dim[3];
    l32Buf := SingleP(lImgBuffer );
    if not lHdr.DiskDataNativeEndian then
        for lI := 1 to lInVox do
			    l32Buf^[lI] := (Swap4r4i(l32Buf^[lI]))
    else  //convert integer to float
			 for lI := 1 to lInVox do
			  l32Buf^[lI] := Conv4r4i(l32Buf^[lI]);
    lHdr.NIFTIHdr.datatype := kDT_FLOAT;
    lHdr.DiskDataNativeEndian := true;
end;//Int32ToFloat

procedure Float32RemoveNAN (var lHdr: TMRIcroHdr; var lImgBuffer: byteP);
//set "Not-A-Number" values to be zero... SPM uses NaN for voxels it can not compute
var
  lI,lInVox: integer;
  l32Buf : SingleP;
begin
	  if lHdr.NIFTIHdr.datatype <> kDT_FLOAT then
      exit;
    lInVox :=  lHdr.NIFTIhdr.dim[1] *  lHdr.NIFTIhdr.dim[2] * lHdr.NIFTIhdr.dim[3];
    l32Buf := SingleP(lImgBuffer );
    for lI := 1 to lInVox do
			  if specialsingle(l32Buf^[lI]) then l32Buf^[lI] :=0.0;

end;//Float32RemoveNAN

function Reslice2TargCore (var lSrcHdr: TMRIcroHdr; var lSrcBuffer: bytep;  var lTargHdr: TNIFTIHdr; var lDestHdr: TMRIcroHdr; lTrilinearInterpolation: boolean; lVolume: integer): string;
//output lDestHdr
var
   lPos,lXYs,lXYZs,lXs,lYs,lZs,lXi,lYi,lZi,lX,lY,lZ,
   lXo,lYo,lZo,lMinY,lMinZ,lMaxY,lMaxZ,lBPP,lXYZ: integer;
   lXrM1,lYrM1,lZrM1,lXreal,lYreal,lZreal,
   lZx,lZy,lZz,lYx,lYy,lYz,
   lInMinX,lInMinY,lInMinZ, lOutMinX,lOutMinY,lOutMinZ: single;
   lXx,lXy,lXz: Singlep0;
   l32fs,l32f : SingleP;
   l32is,l32i : LongIntP;
   l16is,l16i : SmallIntP;
   l8i,l8is: bytep;
   lMat: TMatrix;
   lOverlap: boolean;
begin
     result := '';
     //lOverlap := false;
     //if not NIFTIhdr_LoadImg (lSrcName, lSrcHdr, lSrcBuffer,lVolume) then  exit;
          lOverlap := false;
     //convert 32-bit int to 32-bit float....
     Int32ToFloat (lSrcHdr, lSrcBuffer);
     Float64ToFloat32(lSrcHdr, lSrcBuffer);
     NIFTIhdr_UnswapImg (lSrcHdr,lSrcBuffer); //ensures image data is in native byteorder
     Float32RemoveNAN(lSrcHdr,lSrcBuffer);
     RGB24ToByte (lSrcHdr, lSrcBuffer,lVolume);
     //AbsFloat(lSrcHdr, lSrcBuffer);
     case lSrcHdr.NIFTIhdr.datatype of
        kDT_UNSIGNED_CHAR : lBPP := 1;
	      kDT_SIGNED_SHORT: lBPP := 2;
        kDT_SIGNED_INT:lBPP := 4;
	      kDT_FLOAT: lBPP := 4;
        kDT_RGB: lBPP := 1;
         else begin
             Msg('NII reslice error: datatype not supported.');
             exit;
         end;
     end; //case
     lMat := Voxel2Voxel (lTargHdr,lSrcHdr.NIFTIhdr);
     lDestHdr {.NIFTIhdr} := lSrcHdr {.NIFTIhdr}; //destination has the comments and voxel BPP of source
     CopyHdrMat(lTargHdr,lDestHdr.NIFTIhdr);//destination has dimensions and rotations of destination
     lXs := lSrcHdr.NIFTIhdr.Dim[1];
     lYs := lSrcHdr.NIFTIhdr.Dim[2];
     lZs := lSrcHdr.NIFTIhdr.Dim[3];
     lXYs:=lXs*lYs; //slicesz
     lXYZs := lXYs*lZs;
     lX := lDestHdr.NIFTIhdr.Dim[1];
     lY := lDestHdr.NIFTIhdr.Dim[2];
     lZ := lDestHdr.NIFTIhdr.Dim[3];
     lDestHdr.NIFTIhdr.Dim[4] := 1;
     //load dataset
     NIFTIhdr_UnswapImg(lSrcHdr, lSrcBuffer);//interpolation requires data is in native endian
     { We will set min/max after scaling..
     NIFTIhdr_MinMaxImg(lSrcHdr, lSrcBuffer);
     lDestHdr.GlMinUnscaledS := lSrcHdr.GlMinUnscaledS;
     lDestHdr.GlMaxUnscaledS := lSrcHdr.GlMaxUnscaledS; }
     l8is := (@lSrcBuffer^);

     GetMem(lDestHdr.ImgBufferUnaligned ,(lBPP*lX*lY*lZ)+15);
     {$IFDEF FPC}
     lDestHdr.ImgBuffer := Align(lDestHdr.ImgBufferUnaligned,16); // not commented - check this
     {$ELSE}
     lDestHdr.ImgBuffer := ByteP($fffffff0 and (integer(lDestHdr.ImgBufferUnaligned)+15));
     {$ENDIF}
     //lPos := 1;
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : l8i  := @lDestHdr.ImgBuffer^;
	        kDT_SIGNED_SHORT: l16i := SmallIntP(@lDestHdr.ImgBuffer^ );
          kDT_SIGNED_INT:l32i := LongIntP(@lDestHdr.ImgBuffer^);
	        kDT_FLOAT: l32f := SingleP(@lDestHdr.ImgBuffer^ );
     end; //case
     case lSrcHdr.NIFTIhdr.datatype of
           //kDT_UNSIGNED_CHAR : l8is := l8is;
	        kDT_SIGNED_SHORT: l16is := SmallIntP(l8is );
          kDT_SIGNED_INT:l32is := LongIntP(l8is );
	        kDT_FLOAT: l32fs := SingleP(l8is );
     end; //case
     //next clear image

     case lSrcHdr.NIFTIhdr.datatype of
           kDT_UNSIGNED_CHAR : for lPos := 1 to (lX*lY*lZ) do l8i^[lPos] := 0;
	        kDT_SIGNED_SHORT: for lPos := 1 to (lX*lY*lZ) do l16i^[lPos] := 0;
          kDT_SIGNED_INT:for lPos := 1 to (lX*lY*lZ) do l32i^[lPos] := 0;
	        kDT_FLOAT: for lPos := 1 to (lX*lY*lZ) do l32f^[lPos] := 0;
     end; //case

     //now we can apply the transforms...
     //build lookup table - speed up inner loop
     getmem(lXx, lX*sizeof(single));
     getmem(lXy, lX*sizeof(single));
     getmem(lXz, lX*sizeof(single));
     for lXi := 0 to (lX-1) do begin
      lXx^[lXi] := lXi*lMat.matrix[1][1];
      lXy^[lXi] := lXi*lMat.matrix[2][1];
      lXz^[lXi] := lXi*lMat.matrix[3][1];
     end;
     lPos := 0;
if lTrilinearInterpolation  then begin
     for lZi := 0 to (lZ-1) do begin
         //these values are the same for all voxels in the slice
         // compute once per slice
         lZx := lZi*lMat.matrix[1][3];
         lZy := lZi*lMat.matrix[2][3];
         lZz := lZi*lMat.matrix[3][3];
         for lYi := 0 to (lY-1) do begin
             //these values change once per row
             // compute once per row
             lYx :=  lYi*lMat.matrix[1][2];
             lYy :=  lYi*lMat.matrix[2][2];
             lYz :=  lYi*lMat.matrix[3][2];
             for lXi := 0 to (lX-1) do begin
                 //compute each column
                 inc(lPos);

                 lXreal := (lXx^[lXi]+lYx+lZx+lMat.matrix[1][4]);
                 lYreal := (lXy^[lXi]+lYy+lZy+lMat.matrix[2][4]);
                 lZreal := (lXz^[lXi]+lYz+lZz+lMat.matrix[3][4]);
                 //need to test Xreal as -0.01 truncates to zero
                 if (lXreal >= 0) and (lYreal >= 0{1}) and (lZreal >= 0{1}) and
                     (lXreal < (lXs -1)) and (lYreal < (lYs -1) ) and (lZreal < (lZs -1))
                  then begin
                    //compute the contribution for each of the 8 source voxels
                    //nearest to the target
                    lOverlap := true;
			              lXo := trunc(lXreal);
			              lYo := trunc(lYreal);
			              lZo := trunc(lZreal);
			              lXreal := lXreal-lXo;
			              lYreal := lYreal-lYo;
			              lZreal := lZreal-lZo;
                    lXrM1 := 1-lXreal;
			              lYrM1 := 1-lYreal;
			              lZrM1 := 1-lZreal;
			              lMinY := lYo*lXs;
			              lMinZ := lZo*lXYs;
			              lMaxY := lMinY+lXs;
			              lMaxZ := lMinZ+lXYs;
                    inc(lXo);//images incremented from 1 not 0
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : begin// l8is := l8is;
                          l8i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l8is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l8is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l8is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l8is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l8is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l8is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l8is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l8is^[lXo+1+lMaxY+lMaxZ]) );
          end;
	  kDT_SIGNED_SHORT: begin
                          l16i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l16is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l16is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l16is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l16is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l16is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l16is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l16is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l16is^[lXo+1+lMaxY+lMaxZ]) );
          end;
          kDT_SIGNED_INT:begin
                          l32i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l32is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l32is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l32is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l32is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l32is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l32is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l32is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l32is^[lXo+1+lMaxY+lMaxZ]) );
          end;
	  kDT_FLOAT: begin  //note - we do not round results - all intensities might be frational...
                          l32f^[lPos] :=
                            (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l32fs^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l32fs^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l32fs^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l32fs^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l32fs^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l32fs^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l32fs^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l32fs^[lXo+1+lMaxY+lMaxZ]) );
          end;
     end; //case

                 end; //if voxel is in source image's bounding box
             end;//z
         end;//y
     end;//z
end else begin //if trilinear, else nearest neighbor

     for lZi := 0 to (lZ-1) do begin
         //these values are the same for all voxels in the slice
         // compute once per slice
         lZx := lZi*lMat.matrix[1][3];
         lZy := lZi*lMat.matrix[2][3];
         lZz := lZi*lMat.matrix[3][3];
         for lYi := 0 to (lY-1) do begin
             //these values change once per row
             // compute once per row
             lYx :=  lYi*lMat.matrix[1][2];
             lYy :=  lYi*lMat.matrix[2][2];
             lYz :=  lYi*lMat.matrix[3][2];
             for lXi := 0 to (lX-1) do begin
                 //compute each column
                 inc(lPos);
                 lXo := round(lXx^[lXi]+lYx+lZx+lMat.matrix[1][4]);
                 lYo := round(lXy^[lXi]+lYy+lZy+lMat.matrix[2][4]);
                 lZo := round(lXz^[lXi]+lYz+lZz+lMat.matrix[3][4]);
                 //if lZo <> 0 then
                 // fx(lZo);
                 //need to test Xreal as -0.01 truncates to zero
                 if (lXo >= 0) and (lYo >= 0{1}) and (lZo >= 0{1}) and
                     (lXo < (lXs -1)) and (lYo < (lYs -1) ) and (lZo < (lZs {-1}))
                  then begin
                    lOverlap := true;
                    inc(lXo);//images incremented from 1 not 0
			              lYo := lYo*lXs;
			              lZo := lZo*lXYs;
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : // l8is := l8is;
                          l8i^[lPos] :=l8is^[lXo+lYo+lZo];
	  kDT_SIGNED_SHORT: l16i^[lPos] := l16is^[lXo+lYo+lZo];
    kDT_SIGNED_INT:l32i^[lPos] := l32is^[lXo+lYo+lZo];
	  kDT_FLOAT: l32f^[lPos] := l32fs^[lXo+lYo+lZo];
     end; //case
                 end; //if voxel is in source image's bounding box
             end;//z
         end;//y
     end;//z

end;

     //release lookup tables
     freemem(lXx);
     freemem(lXy);
     freemem(lXz);
     //check to see if image is empty...
     (*lPos := 1;
     case lSrcHdr.NIFTIhdr.datatype of
        kDT_UNSIGNED_CHAR : while (lPos <= (lX*lY*lZ)) and (l8i^[lPos] = 0) do inc(lPos);
        kDT_SIGNED_SHORT: while (lPos <= (lX*lY*lZ)) and (l16i^[lPos] = 0) do inc(lPos);
        kDT_SIGNED_INT:while (lPos <= (lX*lY*lZ)) and (l32i^[lPos] = 0) do inc(lPos);
	      kDT_FLOAT: while (lPos <= (lX*lY*lZ)) and (l32f^[lPos] = 0) do inc(lPos);
     end; //case
     if lPos <= (lX*lY*lZ) then  //image not empty
        //Msg('Overlap')
        //result :=  SaveNIfTICore (lDestName, lBuffAligned, kNIIImgOffset+1, lDestHdr, lPrefs,lByteSwap);
     else
         Msg('Overlay image does not overlap with background image.');  *)
     if not lOverlap then
         Msg('Overlay image does not overlap with background image.');
     //Freemem(lBuffUnaligned);
     lDestHdr.ImgBufferItems := lX*lY*lZ;
     case lSrcHdr.NIFTIhdr.datatype of
      kDT_UNSIGNED_CHAR :lDestHdr.ImgBufferBPP :=1;
      kDT_SIGNED_SHORT: lDestHdr.ImgBufferBPP :=2;
      kDT_SIGNED_INT:lDestHdr.ImgBufferBPP :=4;
	    kDT_FLOAT: lDestHdr.ImgBufferBPP :=4;
     end; //case
     NIFTIhdr_MinMaxImg(lDestHdr,lDestHdr.ImgBuffer);//set global min/max
     result := 'OK';
end;

function Reslice2Targ (lSrcName: string; var lTargHdr: TNIFTIHdr; var lDestHdr: TMRIcroHdr; lTrilinearInterpolation: boolean; lVolume: integer): string;
var
   lSrcBuffer: bytep;
   lSrcHdr: TMRIcroHdr;
begin
     result := '';
     if not NIFTIhdr_LoadImg (lSrcName, lSrcHdr, lSrcBuffer,lVolume) then  exit;
     result := Reslice2TargCore (lSrcHdr, lSrcBuffer, lTargHdr, lDestHdr, lTrilinearInterpolation, lVolume);
     Freemem(lSrcBuffer);
end;

(*function Reslice2Targ (lSrcName: string; var lTargHdr: TNIFTIHdr; var lDestHdr: TMRIcroHdr; lTrilinearInterpolation: boolean; lVolume: integer): string;
var
   lPos,lXYs,lXYZs,lXs,lYs,lZs,lXi,lYi,lZi,lX,lY,lZ,
   lXo,lYo,lZo,lMinY,lMinZ,lMaxY,lMaxZ,lBPP,lXYZ: integer;
   lXrM1,lYrM1,lZrM1,lXreal,lYreal,lZreal,
   lZx,lZy,lZz,lYx,lYy,lYz,
   lInMinX,lInMinY,lInMinZ, lOutMinX,lOutMinY,lOutMinZ: single;
   lXx,lXy,lXz: Singlep0;
   l32fs,l32f : SingleP;
   l32is,l32i : LongIntP;
   l16is,l16i : SmallIntP;
   l8i,l8is,lSrcBuffer: bytep;
   lMat: TMatrix;
   lSrcHdr: TMRIcroHdr;
   lOverlap: boolean;
begin
     result := '';
     lOverlap := false;
     if not NIFTIhdr_LoadImg (lSrcName, lSrcHdr, lSrcBuffer,lVolume) then  exit;
          lOverlap := false;
     //convert 32-bit int to 32-bit float....
     Int32ToFloat (lSrcHdr, lSrcBuffer);
     Float64ToFloat32(lSrcHdr, lSrcBuffer);
     NIFTIhdr_UnswapImg (lSrcHdr,lSrcBuffer); //ensures image data is in native byteorder
     Float32RemoveNAN(lSrcHdr,lSrcBuffer);
     RGB24ToByte (lSrcHdr, lSrcBuffer,lVolume);
     //AbsFloat(lSrcHdr, lSrcBuffer);
     case lSrcHdr.NIFTIhdr.datatype of
        kDT_UNSIGNED_CHAR : lBPP := 1;
	      kDT_SIGNED_SHORT: lBPP := 2;
        kDT_SIGNED_INT:lBPP := 4;
	      kDT_FLOAT: lBPP := 4;
        kDT_RGB: lBPP := 1;
         else begin
             Msg('NII reslice error: datatype not supported.');
             exit;
         end;
     end; //case
     lMat := Voxel2Voxel (lTargHdr,lSrcHdr.NIFTIhdr);
     lDestHdr {.NIFTIhdr} := lSrcHdr {.NIFTIhdr}; //destination has the comments and voxel BPP of source
     CopyHdrMat(lTargHdr,lDestHdr.NIFTIhdr);//destination has dimensions and rotations of destination
     lXs := lSrcHdr.NIFTIhdr.Dim[1];
     lYs := lSrcHdr.NIFTIhdr.Dim[2];
     lZs := lSrcHdr.NIFTIhdr.Dim[3];
     lXYs:=lXs*lYs; //slicesz
     lXYZs := lXYs*lZs;
     lX := lDestHdr.NIFTIhdr.Dim[1];
     lY := lDestHdr.NIFTIhdr.Dim[2];
     lZ := lDestHdr.NIFTIhdr.Dim[3];
     lDestHdr.NIFTIhdr.Dim[4] := 1;
     //load dataset
     NIFTIhdr_UnswapImg(lSrcHdr, lSrcBuffer);//interpolation requires data is in native endian
     { We will set min/max after scaling..
     NIFTIhdr_MinMaxImg(lSrcHdr, lSrcBuffer);
     lDestHdr.GlMinUnscaledS := lSrcHdr.GlMinUnscaledS;
     lDestHdr.GlMaxUnscaledS := lSrcHdr.GlMaxUnscaledS; }
     l8is := (@lSrcBuffer^);

     GetMem(lDestHdr.ImgBufferUnaligned ,(lBPP*lX*lY*lZ)+15);
     {$IFDEF FPC}
     lDestHdr.ImgBuffer := Align(lDestHdr.ImgBufferUnaligned,16); // not commented - check this
     {$ELSE}
     lDestHdr.ImgBuffer := ByteP($fffffff0 and (integer(lDestHdr.ImgBufferUnaligned)+15));
     {$ENDIF}
     //lPos := 1;
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : l8i  := @lDestHdr.ImgBuffer^;
	        kDT_SIGNED_SHORT: l16i := SmallIntP(@lDestHdr.ImgBuffer^ );
          kDT_SIGNED_INT:l32i := LongIntP(@lDestHdr.ImgBuffer^);
	        kDT_FLOAT: l32f := SingleP(@lDestHdr.ImgBuffer^ );
     end; //case
     case lSrcHdr.NIFTIhdr.datatype of
           //kDT_UNSIGNED_CHAR : l8is := l8is;
	        kDT_SIGNED_SHORT: l16is := SmallIntP(l8is );
          kDT_SIGNED_INT:l32is := LongIntP(l8is );
	        kDT_FLOAT: l32fs := SingleP(l8is );
     end; //case
     //next clear image

     case lSrcHdr.NIFTIhdr.datatype of
           kDT_UNSIGNED_CHAR : for lPos := 1 to (lX*lY*lZ) do l8i^[lPos] := 0;
	        kDT_SIGNED_SHORT: for lPos := 1 to (lX*lY*lZ) do l16i^[lPos] := 0;
          kDT_SIGNED_INT:for lPos := 1 to (lX*lY*lZ) do l32i^[lPos] := 0;
	        kDT_FLOAT: for lPos := 1 to (lX*lY*lZ) do l32f^[lPos] := 0;
     end; //case

     //now we can apply the transforms...
     //build lookup table - speed up inner loop
     getmem(lXx, lX*sizeof(single));
     getmem(lXy, lX*sizeof(single));
     getmem(lXz, lX*sizeof(single));
     for lXi := 0 to (lX-1) do begin
      lXx^[lXi] := lXi*lMat.matrix[1][1];
      lXy^[lXi] := lXi*lMat.matrix[2][1];
      lXz^[lXi] := lXi*lMat.matrix[3][1];
     end;
     lPos := 0;
if lTrilinearInterpolation  then begin
     for lZi := 0 to (lZ-1) do begin
         //these values are the same for all voxels in the slice
         // compute once per slice
         lZx := lZi*lMat.matrix[1][3];
         lZy := lZi*lMat.matrix[2][3];
         lZz := lZi*lMat.matrix[3][3];
         for lYi := 0 to (lY-1) do begin
             //these values change once per row
             // compute once per row
             lYx :=  lYi*lMat.matrix[1][2];
             lYy :=  lYi*lMat.matrix[2][2];
             lYz :=  lYi*lMat.matrix[3][2];
             for lXi := 0 to (lX-1) do begin
                 //compute each column
                 inc(lPos);

                 lXreal := (lXx^[lXi]+lYx+lZx+lMat.matrix[1][4]);
                 lYreal := (lXy^[lXi]+lYy+lZy+lMat.matrix[2][4]);
                 lZreal := (lXz^[lXi]+lYz+lZz+lMat.matrix[3][4]);
                 //need to test Xreal as -0.01 truncates to zero
                 if (lXreal >= 0) and (lYreal >= 0{1}) and (lZreal >= 0{1}) and
                     (lXreal < (lXs -1)) and (lYreal < (lYs -1) ) and (lZreal < (lZs -1))
                  then begin
                    //compute the contribution for each of the 8 source voxels
                    //nearest to the target
                    lOverlap := true;
			              lXo := trunc(lXreal);
			              lYo := trunc(lYreal);
			              lZo := trunc(lZreal);
			              lXreal := lXreal-lXo;
			              lYreal := lYreal-lYo;
			              lZreal := lZreal-lZo;
                    lXrM1 := 1-lXreal;
			              lYrM1 := 1-lYreal;
			              lZrM1 := 1-lZreal;
			              lMinY := lYo*lXs;
			              lMinZ := lZo*lXYs;
			              lMaxY := lMinY+lXs;
			              lMaxZ := lMinZ+lXYs;
                    inc(lXo);//images incremented from 1 not 0
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : begin// l8is := l8is;
                          l8i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l8is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l8is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l8is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l8is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l8is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l8is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l8is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l8is^[lXo+1+lMaxY+lMaxZ]) );
          end;
	  kDT_SIGNED_SHORT: begin
                          l16i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l16is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l16is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l16is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l16is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l16is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l16is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l16is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l16is^[lXo+1+lMaxY+lMaxZ]) );
          end;
          kDT_SIGNED_INT:begin
                          l32i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l32is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l32is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l32is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l32is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l32is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l32is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l32is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l32is^[lXo+1+lMaxY+lMaxZ]) );
          end;
	  kDT_FLOAT: begin  //note - we do not round results - all intensities might be frational...
                          l32f^[lPos] :=
                            (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l32fs^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l32fs^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l32fs^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l32fs^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l32fs^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l32fs^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l32fs^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l32fs^[lXo+1+lMaxY+lMaxZ]) );
          end;
     end; //case

                 end; //if voxel is in source image's bounding box
             end;//z
         end;//y
     end;//z
end else begin //if trilinear, else nearest neighbor

     for lZi := 0 to (lZ-1) do begin
         //these values are the same for all voxels in the slice
         // compute once per slice
         lZx := lZi*lMat.matrix[1][3];
         lZy := lZi*lMat.matrix[2][3];
         lZz := lZi*lMat.matrix[3][3];
         for lYi := 0 to (lY-1) do begin
             //these values change once per row
             // compute once per row
             lYx :=  lYi*lMat.matrix[1][2];
             lYy :=  lYi*lMat.matrix[2][2];
             lYz :=  lYi*lMat.matrix[3][2];
             for lXi := 0 to (lX-1) do begin
                 //compute each column
                 inc(lPos);
                 lXo := round(lXx^[lXi]+lYx+lZx+lMat.matrix[1][4]);
                 lYo := round(lXy^[lXi]+lYy+lZy+lMat.matrix[2][4]);
                 lZo := round(lXz^[lXi]+lYz+lZz+lMat.matrix[3][4]);
                 //if lZo <> 0 then
                 // fx(lZo);
                 //need to test Xreal as -0.01 truncates to zero
                 if (lXo >= 0) and (lYo >= 0{1}) and (lZo >= 0{1}) and
                     (lXo < (lXs -1)) and (lYo < (lYs -1) ) and (lZo < (lZs {-1}))
                  then begin
                    lOverlap := true;
                    inc(lXo);//images incremented from 1 not 0
			              lYo := lYo*lXs;
			              lZo := lZo*lXYs;
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : // l8is := l8is;
                          l8i^[lPos] :=l8is^[lXo+lYo+lZo];
	  kDT_SIGNED_SHORT: l16i^[lPos] := l16is^[lXo+lYo+lZo];
    kDT_SIGNED_INT:l32i^[lPos] := l32is^[lXo+lYo+lZo];
	  kDT_FLOAT: l32f^[lPos] := l32fs^[lXo+lYo+lZo];
     end; //case
                 end; //if voxel is in source image's bounding box
             end;//z
         end;//y
     end;//z

end;
     Freemem(lSrcBuffer);
     //release lookup tables
     freemem(lXx);
     freemem(lXy);
     freemem(lXz);
     //check to see if image is empty...
     if not lOverlap then
         Msg('Overlay image does not overlap with background image.'); 
     //Freemem(lBuffUnaligned);
     lDestHdr.ImgBufferItems := lX*lY*lZ;
     case lSrcHdr.NIFTIhdr.datatype of
      kDT_UNSIGNED_CHAR :lDestHdr.ImgBufferBPP :=1;
      kDT_SIGNED_SHORT: lDestHdr.ImgBufferBPP :=2;
      kDT_SIGNED_INT:lDestHdr.ImgBufferBPP :=4;
	    kDT_FLOAT: lDestHdr.ImgBufferBPP :=4;
     end; //case
     NIFTIhdr_MinMaxImg(lDestHdr,lDestHdr.ImgBuffer);//set global min/max
     result := 'OK';
end;  *)

(*function Reslice2Targ (lSrcName: string; var lTargHdr: TNIFTIHdr; var lDestHdr: TMRIcroHdr; lTrilinearInterpolation: boolean; lVolume: integer): string;
var
   lPos,lXYs,lXYZs,lXs,lYs,lZs,lXi,lYi,lZi,lX,lY,lZ,
   lXo,lYo,lZo,lMinY,lMinZ,lMaxY,lMaxZ,lBPP,lXYZ: integer;
   lXrM1,lYrM1,lZrM1,lXreal,lYreal,lZreal,
   lZx,lZy,lZz,lYx,lYy,lYz,
   lInMinX,lInMinY,lInMinZ, lOutMinX,lOutMinY,lOutMinZ: single;
   lXx,lXy,lXz: Singlep0;
   l32fs,l32f : SingleP;
   l32is,l32i : LongIntP;
   l16is,l16i : SmallIntP;
   l8i,l8is,lSrcBuffer: bytep;
   lMat: TMatrix;
   lSrcHdr: TMRIcroHdr;
begin
     result := '';
     if not NIFTIhdr_LoadImg (lSrcName, lSrcHdr, lSrcBuffer,lVolume) then  exit;
     //convert 32-bit int to 32-bit float....
     Int32ToFloat (lSrcHdr, lSrcBuffer);
     Float64ToFloat32(lSrcHdr, lSrcBuffer);
     //AbsFloat(lSrcHdr, lSrcBuffer);

     case lSrcHdr.NIFTIhdr.datatype of
        kDT_UNSIGNED_CHAR : lBPP := 1;
	      kDT_SIGNED_SHORT: lBPP := 2;
        kDT_SIGNED_INT:lBPP := 4;
	      kDT_FLOAT: lBPP := 4;
         else begin
             Msg('NII reslice error: datatype not supported.');
             exit;
         end;
     end; //case
     lMat := Voxel2Voxel (lTargHdr,lSrcHdr.NIFTIhdr);
     lDestHdr.NIFTIhdr := lSrcHdr.NIFTIhdr; //destination has the comments and voxel BPP of source
     //lDestHdr.NIFTIhdr.datatype := lSrcHdr.NIFTIhdr.datatype;
     CopyHdrMat(lTargHdr,lDestHdr.NIFTIhdr);//destination has dimensions and rotations of destination
     lXs := lSrcHdr.NIFTIhdr.Dim[1];
     lYs := lSrcHdr.NIFTIhdr.Dim[2];
     lZs := lSrcHdr.NIFTIhdr.Dim[3];
     lXYs:=lXs*lYs; //slicesz
     lXYZs := lXYs*lZs;
     lX := lDestHdr.NIFTIhdr.Dim[1];
     lY := lDestHdr.NIFTIhdr.Dim[2];
     lZ := lDestHdr.NIFTIhdr.Dim[3];
     lDestHdr.NIFTIhdr.Dim[4] := 1;
     //load dataset
     NIFTIhdr_UnswapImg(lSrcHdr, lSrcBuffer);//interpolation requires data is in native endian
     {  We will set min/max after scaling..
     NIFTIhdr_MinMaxImg(lSrcHdr, lSrcBuffer);
     lDestHdr.GlMinUnscaledS := lSrcHdr.GlMinUnscaledS;
     lDestHdr.GlMaxUnscaledS := lSrcHdr.GlMaxUnscaledS;  }
     l8is := (@lSrcBuffer^);
     GetMem(lDestHdr.ImgBufferUnaligned ,(lBPP*lX*lY*lZ)+15);
     {$IFDEF FPC}
     lDestHdr.ImgBuffer := Align(lDestHdr.ImgBufferUnaligned,16); // not commented - check this
     {$ELSE}
     lDestHdr.ImgBuffer := ByteP($fffffff0 and (integer(lDestHdr.ImgBufferUnaligned)+15));
     {$ENDIF}
     lPos := 1;
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : l8i  := @lDestHdr.ImgBuffer^;
	        kDT_SIGNED_SHORT: l16i := SmallIntP(@lDestHdr.ImgBuffer^ );
          kDT_SIGNED_INT:l32i := LongIntP(@lDestHdr.ImgBuffer^);
	        kDT_FLOAT: l32f := SingleP(@lDestHdr.ImgBuffer^ );
     end; //case
     case lSrcHdr.NIFTIhdr.datatype of
           //kDT_UNSIGNED_CHAR : l8is := l8is;
	        kDT_SIGNED_SHORT: l16is := SmallIntP(l8is );
          kDT_SIGNED_INT:l32is := LongIntP(l8is );
	        kDT_FLOAT: l32fs := SingleP(l8is );
     end; //case
     //next clear image

     case lSrcHdr.NIFTIhdr.datatype of
           kDT_UNSIGNED_CHAR : for lPos := 1 to (lX*lY*lZ) do l8i^[lPos] := 0;
	        kDT_SIGNED_SHORT: for lPos := 1 to (lX*lY*lZ) do l16i^[lPos] := 0;
          kDT_SIGNED_INT:for lPos := 1 to (lX*lY*lZ) do l32i^[lPos] := 0;
	        kDT_FLOAT: for lPos := 1 to (lX*lY*lZ) do l32f^[lPos] := 0;
     end; //case

     //now we can apply the transforms...
     //build lookup table - speed up inner loop
     getmem(lXx, lX*sizeof(single));
     getmem(lXy, lX*sizeof(single));
     getmem(lXz, lX*sizeof(single));
     for lXi := 0 to (lX-1) do begin
      lXx^[lXi] := lXi*lMat.matrix[1][1];
      lXy^[lXi] := lXi*lMat.matrix[2][1];
      lXz^[lXi] := lXi*lMat.matrix[3][1];
     end;
     lPos := 0;
if lTrilinearInterpolation  then begin
     for lZi := 0 to (lZ-1) do begin
         //these values are the same for all voxels in the slice
         // compute once per slice
         lZx := lZi*lMat.matrix[1][3];
         lZy := lZi*lMat.matrix[2][3];
         lZz := lZi*lMat.matrix[3][3];
         for lYi := 0 to (lY-1) do begin
             //these values change once per row
             // compute once per row
             lYx :=  lYi*lMat.matrix[1][2];
             lYy :=  lYi*lMat.matrix[2][2];
             lYz :=  lYi*lMat.matrix[3][2];
             for lXi := 0 to (lX-1) do begin
                 //compute each column
                 inc(lPos);

                 lXreal := (lXx^[lXi]+lYx+lZx+lMat.matrix[1][4]);
                 lYreal := (lXy^[lXi]+lYy+lZy+lMat.matrix[2][4]);
                 lZreal := (lXz^[lXi]+lYz+lZz+lMat.matrix[3][4]);
                 //need to test Xreal as -0.01 truncates to zero
                 if (lXreal >= 0) and (lYreal >= 0{1}) and (lZreal >= 0{1}) and
                     (lXreal < (lXs -1)) and (lYreal < (lYs -1) ) and (lZreal < (lZs -1))
                  then begin
                    //compute the contribution for each of the 8 source voxels
                    //nearest to the target
			              lXo := trunc(lXreal);
			              lYo := trunc(lYreal);
			              lZo := trunc(lZreal);
			              lXreal := lXreal-lXo;
			              lYreal := lYreal-lYo;
			              lZreal := lZreal-lZo;
                    lXrM1 := 1-lXreal;
			              lYrM1 := 1-lYreal;
			              lZrM1 := 1-lZreal;
			              lMinY := lYo*lXs;
			              lMinZ := lZo*lXYs;
			              lMaxY := lMinY+lXs;
			              lMaxZ := lMinZ+lXYs;
                    inc(lXo);//images incremented from 1 not 0
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : begin// l8is := l8is;
                          l8i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l8is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l8is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l8is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l8is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l8is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l8is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l8is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l8is^[lXo+1+lMaxY+lMaxZ]) );
          end;
	  kDT_SIGNED_SHORT: begin
                          l16i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l16is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l16is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l16is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l16is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l16is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l16is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l16is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l16is^[lXo+1+lMaxY+lMaxZ]) );
          end;
          kDT_SIGNED_INT:begin
                          l32i^[lPos] :=
                           round (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l32is^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l32is^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l32is^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l32is^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l32is^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l32is^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l32is^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l32is^[lXo+1+lMaxY+lMaxZ]) );
          end;
	  kDT_FLOAT: begin  //note - we do not round results - all intensities might be frational...
                          l32f^[lPos] :=
                            (
		 	   {all min} ( (lXrM1*lYrM1*lZrM1)*l32fs^[lXo+lMinY+lMinZ])
			   {x+1}+((lXreal*lYrM1*lZrM1)*l32fs^[lXo+1+lMinY+lMinZ])
			   {y+1}+((lXrM1*lYreal*lZrM1)*l32fs^[lXo+lMaxY+lMinZ])
			   {z+1}+((lXrM1*lYrM1*lZreal)*l32fs^[lXo+lMinY+lMaxZ])
			   {x+1,y+1}+((lXreal*lYreal*lZrM1)*l32fs^[lXo+1+lMaxY+lMinZ])
			   {x+1,z+1}+((lXreal*lYrM1*lZreal)*l32fs^[lXo+1+lMinY+lMaxZ])
			   {y+1,z+1}+((lXrM1*lYreal*lZreal)*l32fs^[lXo+lMaxY+lMaxZ])
			   {x+1,y+1,z+1}+((lXreal*lYreal*lZreal)*l32fs^[lXo+1+lMaxY+lMaxZ]) );
          end;
     end; //case

                 end; //if voxel is in source image's bounding box
             end;//z
         end;//y
     end;//z
end else begin //if trilinear, else nearest neighbor

     for lZi := 0 to (lZ-1) do begin
         //these values are the same for all voxels in the slice
         // compute once per slice
         lZx := lZi*lMat.matrix[1][3];
         lZy := lZi*lMat.matrix[2][3];
         lZz := lZi*lMat.matrix[3][3];
         for lYi := 0 to (lY-1) do begin
             //these values change once per row
             // compute once per row
             lYx :=  lYi*lMat.matrix[1][2];
             lYy :=  lYi*lMat.matrix[2][2];
             lYz :=  lYi*lMat.matrix[3][2];
             for lXi := 0 to (lX-1) do begin
                 //compute each column
                 inc(lPos);
                 lXo := round(lXx^[lXi]+lYx+lZx+lMat.matrix[1][4]);
                 lYo := round(lXy^[lXi]+lYy+lZy+lMat.matrix[2][4]);
                 lZo := round(lXz^[lXi]+lYz+lZz+lMat.matrix[3][4]);
                 //if lZo <> 0 then
                 // fx(lZo);
                 //need to test Xreal as -0.01 truncates to zero
                 if (lXo >= 0) and (lYo >= 0{1}) and (lZo >= 0{1}) and
                     (lXo < (lXs -1)) and (lYo < (lYs -1) ) and (lZo < (lZs {-1}))
                  then begin
                    inc(lXo);//images incremented from 1 not 0
			              lYo := lYo*lXs;
			              lZo := lZo*lXYs;
     case lSrcHdr.NIFTIhdr.datatype of
          kDT_UNSIGNED_CHAR : // l8is := l8is;
                          l8i^[lPos] :=l8is^[lXo+lYo+lZo];
	  kDT_SIGNED_SHORT: l16i^[lPos] := l16is^[lXo+lYo+lZo];
    kDT_SIGNED_INT:l32i^[lPos] := l32is^[lXo+lYo+lZo];
	  kDT_FLOAT: l32f^[lPos] := l32fs^[lXo+lYo+lZo];
     end; //case


                 end; //if voxel is in source image's bounding box

             end;//z
         end;//y
     end;//z

end;
     Freemem(lSrcBuffer);
     //release lookup tables
     freemem(lXx);
     freemem(lXy);
     freemem(lXz);
     //check to see if image is empty...
     lPos := 1;
     case lSrcHdr.NIFTIhdr.datatype of
        kDT_UNSIGNED_CHAR : while (lPos <= (lX*lY*lZ)) and (l8i^[lPos] = 0) do inc(lPos);
        kDT_SIGNED_SHORT: while (lPos <= (lX*lY*lZ)) and (l16i^[lPos] = 0) do inc(lPos);
        kDT_SIGNED_INT:while (lPos <= (lX*lY*lZ)) and (l32i^[lPos] = 0) do inc(lPos);
	      kDT_FLOAT: while (lPos <= (lX*lY*lZ)) and (l32f^[lPos] = 0) do inc(lPos);
     end; //case
     if lPos <= (lX*lY*lZ) then  //image not empty
        //Msg('Overlap')
        //result :=  SaveNIfTICore (lDestName, lBuffAligned, kNIIImgOffset+1, lDestHdr, lPrefs,lByteSwap);
     else
         Msg('Overlay image does not overlap with background image.');
     //Freemem(lBuffUnaligned);
     lDestHdr.ImgBufferItems := lX*lY*lZ;
     case lSrcHdr.NIFTIhdr.datatype of
      kDT_UNSIGNED_CHAR :lDestHdr.ImgBufferBPP :=1;
      kDT_SIGNED_SHORT: lDestHdr.ImgBufferBPP :=2;
      kDT_SIGNED_INT:lDestHdr.ImgBufferBPP :=4;
	    kDT_FLOAT: lDestHdr.ImgBufferBPP :=4;
     end; //case
     {if lSrcHdr.NIFTIhdr.datatype = kDT_FLOAT then begin
      lInMinX := l32f^[1];
      lInMinY := l32f^[1];
      for lPos := 1 to (lX*lY*lZ) do begin
        if l32f^[lPos] > lInMinX then
          lInMinX :=l32f^[lPos];
        if l32f^[lPos] < lInMinY then
          lInMinY :=l32f^[lPos];
      end;
      fx(lInMinY,lInMinX);
     end; }
     NIFTIhdr_MinMaxImg(lDestHdr,lDestHdr.ImgBuffer);//set global min/max
     result := 'OK';
end;
*)

(*function ResliceImgNIfTI (lTargetImgName,lSrcImgName,lOutputName: string): boolean;
label
 666;
var
   lReslice : boolean;
   lDestHdr,lSrcHdr: TMRIcroHdr;
   lSrcMat,lDestMat,lSrcMatINv,lDestMatInv,lMat: TMatrix;
   lOffX,lOffY,lOffZ: single;
   D: double;
begin
     result := false;
     if not fileexists(lTargetImgName) then exit;
     if not fileexists(lSrcImgName) then exit;
     ImgForm.CloseImagesClick(nil);
     lReslice := gBGImg.ResliceOnLoad;
     gBGImg.ResliceOnLoad := false;
     //if not HdrForm.OpenAndDisplayHdr(lTargetImgName,lDestHdr) then goto 666;
     if not NIFTIhdr_LoadHdr(lTargetImgName, lDestHdr) then goto 666;
     if not NIFTIhdr_LoadHdr(lSrcImgName, lSrcHdr) then goto 666;
     if not ImgForm.OpenAndDisplayImg(lSrcImgName,false) then exit;
     if not Qx(lDestHdr,lSrcHdr,lOutputName) then goto 666;

     result := true;
666:
     if not result then
        showmessage('Error applying transform '+lSrcImgName+'->'+lTargetImgName);
     gBGImg.ResliceOnLoad := lReslice;
end;  *)

end.
