/* ***** BEGIN LICENSE BLOCK *****
 *
 * This file is part of Weave.
 *
 * The Initial Developer of Weave is the Institute for Visualization
 * and Perception Research at the University of Massachusetts Lowell.
 * Portions created by the Initial Developer are Copyright (C) 2008-2015
 * the Initial Developer. All Rights Reserved.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at http://mozilla.org/MPL/2.0/.
 * 
 * ***** END LICENSE BLOCK ***** */

package weave.data
{
	import flash.geom.Point;
	import flash.utils.ByteArray;
	
	import org.openscales.proj4as.Proj4as;
	import org.openscales.proj4as.ProjConstants;
	import org.openscales.proj4as.ProjPoint;
	import org.openscales.proj4as.ProjProjection;
	
	import weave.api.data.IAttributeColumn;
	import weave.api.data.IProjectionManager;
	import weave.api.data.IProjector;
	import weave.api.newDisposableChild;
	import weave.api.objectWasDisposed;
	import weave.api.primitives.IBounds2D;
	import weave.data.AttributeColumns.ProxyColumn;
	import weave.primitives.Bounds2D;
	import weave.primitives.Dictionary2D;
	
	/**
	 * An interface for reprojecting columns of geometries and individual coordinates.
	 * 
	 * @author adufilie
	 * @author kmonico
	 */	
	public class ProjectionManager implements IProjectionManager
	{
		public function ProjectionManager()
		{
			if (!projectionsInitialized)
				initializeProjections();
		}
		
		[Embed(source="/weave/resources/ProjDatabase.dat", mimeType="application/octet-stream")]
		private static const ProjDatabase:Class;
		private static var projectionsInitialized:Boolean = false;

		/**
		 * This function decompresses the projection database and loads the definitions into ProjProjection.defs.
		 */
		private static function initializeProjections():void
		{
			// http://mathworld.wolfram.com/AlbersEqual-AreaConicProjection.html
			ProjProjection.defs['EPSG:9822'] = '+title=Albers Equal-Area Conic +proj=aea +lat_1=0 +lat_2=60 +lat_0=0 +lon_0=0 +x_0=0 +y_0=0 +ellps=WGS84 +datum=WGS84 +units=m +no_defs';
			
			// http://geeohspatial.blogspot.com/2013/03/custom-srss-in-postgis-and-qgis.html
			ProjProjection.defs['SR-ORG:6703'] = '+title=USA_Contiguous_Albers_Equal_Area_Conic_USGS_version +proj=aea +lat_1=29.5 +lat_2=45.5 +lat_0=23 +lon_0=-96 +x_0=0 +y_0=0 +ellps=GRS80 +datum=NAD83 +units=m +no_defs';

			//ProjProjection.defs['aeac-us'] = '+title=Albers Equal-Area Conic +proj=aea +lat_1=37.25 +lat_2=40.25 +lat_0=36 +lon_0=-72 +x_0=0 +y_0=0 +ellps=WGS84 +datum=WGS84 +units=m +no_defs';
			
			ProjProjection.defs['EPSG:102736'] = "+title=NAD 1983 StatePlane Tennessee FIPS 4100 Feet +proj=lcc +lat_1=35.25 +lat_2=36.41666666666666 +lat_0=34.33333333333334 +lon_0=-86 +x_0=600000.0000000001 +y_0=0 +ellps=GRS80 +datum=NAD83 +to_meter=0.3048006096012192 +no_defs";
			ProjProjection.defs['VANDG'] = "+title=Van Der Grinten +proj=vandg +x_0=0 +y_0=0 +lon_0=0";
			
			var ba:ByteArray = (new ProjDatabase()) as ByteArray;
			ba.uncompress();
			var defs:Object = ba.readObject();
			for (var key:String in defs)
				ProjProjection.defs[key] = defs[key];
			
			projectionsInitialized = true;
		}


		/**
		 * This is a multi-dimensional lookup for ProxyColumn objects containing reprojected geometries:   (unprojectedColumn, destinationSRS) -> ProxyColumn
		 */		
		private const _reprojectedColumnCache_d2d_col_srs:Dictionary2D = new Dictionary2D(true); // weak links to be gc-friendly
		
		/**
		 * @inheritDoc
		 */
		public function getProjectedGeometryColumn(geometryColumn:IAttributeColumn, destinationProjectionSRS:String):IAttributeColumn
		{
			if (!geometryColumn)
				return null;
				
			// if there is no projection specified, return the original column
			if (!destinationProjectionSRS)
				return geometryColumn;
			
			// check the cache
			var worker:WorkerThread = _reprojectedColumnCache_d2d_col_srs.get(geometryColumn, destinationProjectionSRS);
			
			// if worker doesn't exist yet or was disposed, (re)create it
			if (!worker || objectWasDisposed(worker))
			{
				worker = new WorkerThread(this, geometryColumn, destinationProjectionSRS);
				_reprojectedColumnCache_d2d_col_srs.set(geometryColumn, destinationProjectionSRS, worker);
			}

			return worker.reprojectedColumn;
		}
		
		/**
		 * This function will check if a projection is defined for a given SRS code.
		 * @param srsCode The SRS code of the projection.
		 * @return A boolean indicating true if the projection is defined and false otherwise.
		 */
		public function projectionExists(srsCode:String):Boolean
		{
			if (srsCode && ProjProjection.defs[srsCode.toUpperCase()])
				return true;
			else
				return false;			
		}
		
		/**
		 * This function will return an IProjector object that can be used to reproject points.
		 * @param sourceSRS The SRS code of the source projection.
		 * @param destinationSRS The SRS code of the destination projection.
		 * @return An IProjector object that reprojects from sourceSRS to destinationSRS.
		 */
		public function getProjector(sourceSRS:String, destinationSRS:String):IProjector
		{
			var lookup:String = sourceSRS + ';' + destinationSRS;
			var projector:IProjector = _projectorCache[lookup] as IProjector;
			if (!projector)
			{
				var source:ProjProjection = getProjection(sourceSRS);
				var dest:ProjProjection = getProjection(destinationSRS);
				projector = new Projector(source, dest);
				_projectorCache[lookup] = projector;
			}
			return projector;
		}

		/**
		 * This function will transform a point from the sourceSRS to the destinationSRS.
		 * @param sourceSRS The SRS code of the source projection.
		 * @param destinationSRS The SRS code of the destination projection.
		 * @param inputAndOutput The point to transform. This is then used as the return value.
		 * @return The transformed point, inputAndOutput, or null if the transform failed.
		 */
		public function transformPoint(sourceSRS:String, destinationSRS:String, inputAndOutput:Point):Point
		{
			var sourceProj:ProjProjection = getProjection(sourceSRS);
			var destinationProj:ProjProjection = getProjection(destinationSRS);
			
			_tempProjPoint.x = inputAndOutput.x;
			_tempProjPoint.y = inputAndOutput.y;
			_tempProjPoint.z = NaN; // this is important in case the projection reads the z value.
			
			if (Proj4as.transform(sourceProj, destinationProj, _tempProjPoint))
			{
				inputAndOutput.x = _tempProjPoint.x;
				inputAndOutput.y = _tempProjPoint.y;
				return inputAndOutput;
			}
			
			inputAndOutput.x = NaN;
			inputAndOutput.y = NaN;
			return null;
		}
		
		private const _tempBounds:IBounds2D = new Bounds2D(); // reusable temporary object
		
		/**
		 * This function will transform bounds from the sourceSRS to the destinationSRS. The resulting
		 * bounds are an approximation.
		 * 
		 * @param sourceSRS The SRS code of the source projection.
		 * @param destinationSRS The SRS code of the destination projection.
		 * @param inputAndOutput The bounds to transform. This is then used as the return value.
		 * @param xGridSize The number of points in the grid in the x direction.
		 * @param yGridSize The number of points in the grid in the y direction.
		 * @return The transformed bounds, inputAndOutput.
		 */
		public function transformBounds(sourceSRS:String, destinationSRS:String, inputAndOutput:IBounds2D, 
			xGridSize:int = 32, yGridSize:int = 32):IBounds2D
		{
			//// NOTE: this function is optimized for speed 
			var bounds:Bounds2D = inputAndOutput as Bounds2D;
			var xn:int = xGridSize;
			var yn:int = yGridSize; // same as above
			var w:Number = bounds.getWidth();
			var h:Number = bounds.getHeight();
			var xMin:Number = bounds.xMin;
			var xMax:Number = bounds.xMax;
			var yMin:Number = bounds.yMin;
			var yMax:Number = bounds.yMax;
			var projector:IProjector = getProjector(sourceSRS, destinationSRS); // fast projection

			// NOTE: We can't just reproject the coordinates around the edges because the edges may include
			// invalid coordinates and then we would miss the valid coordinates in the middle of the bounds.
			
			// reproject points along the edges and zig zag inside
			// o--o--o--o--o
			// |  |  |  |  |
			// o--o-- --o--o
			// |  |  |  |  |
			// o-- --o-- --o
			// |  |  |  |  |
			// o--o-- --o--o
			// |  |  |  |  |
			// o--o--o--o--o
			// most of the work is through projecting a point, and this distribution tries to minimize
			// the work without sacrificing accuracy
			_tempBounds.reset();
			var oddX:Boolean = true;
			for (var x:int = 0; x <= xn; ++x)
			{
				oddX = !oddX;
				var oddY:Boolean = true;
				for (var y:int = 0; y <= yn; ++y)
				{
					oddY = !oddY;

					if (x == 0 || y == 0 || x == xn || y == yn 
						|| (oddX && oddY) || (!oddX && !oddY))
					{
						_tempPoint.x = xMin + x * w / xn;
						_tempPoint.y = yMin + y * h / yn;
						projector.reproject(_tempPoint);
						if (isFinite(_tempPoint.x) && isFinite(_tempPoint.y))
							_tempBounds.includePoint(_tempPoint);
					}
				}
			}
			
			inputAndOutput.copyFrom(_tempBounds);
			return inputAndOutput;
		}
		
		/**
		 * getProjection
		 * @param srsCode The SRS Code of a projection.
		 * @return A cached ProjProjection object for the specified SRS Code.
		 */
		public function getProjection(srsCode:String):ProjProjection
		{
			if (!srsCode)
				return null;
			
			srsCode = srsCode.toUpperCase();
			
			if (_srsToProjMap.hasOwnProperty(srsCode))
				return _srsToProjMap[srsCode];
			
			if (projectionExists(srsCode))
				return _srsToProjMap[srsCode] = new ProjProjection(srsCode);
			
			return null;
		}
		
		/**
		 * This maps a pair of SRS codes separated by a semicolon to a Projector object.
		 */
		private const _projectorCache:Object = {};

		/**
		 * This maps an SRS Code to a cached ProjProjection object for that code.
		 */
		private const _srsToProjMap:Object = {};
		
		/**
		 * This is a temporary object used for single point transformations.
		 */
		private const _tempProjPoint:ProjPoint = new ProjPoint();
		
		/**
		 * This is a temporary object used only in transformBounds.
		 */
		private const _tempPoint:Point = new Point();

		/**
		 * This will output the lat,long bounds commonly used for map tiles.  This bounds does not include the poles.
		 * @param output
		 */		
		public static function getMercatorTileBoundsInLatLong(output:IBounds2D):void
		{
			var minWorldLon:Number = -180.0 + ProjConstants.EPSLN; // because Proj4 wraps coordinates
			var maxWorldLon:Number = 180.0 - ProjConstants.EPSLN; // because Proj4 wraps coordinates
			var minWorldLat:Number = -Math.atan(ProjConstants.sinh(Math.PI)) * ProjConstants.R2D;
			var maxWorldLat:Number = Math.atan(ProjConstants.sinh(Math.PI)) * ProjConstants.R2D;
			
			output.setBounds(minWorldLon, minWorldLat, maxWorldLon, maxWorldLat);
		}
		
		public static function getProjectionFromURN(ogc_crs_urn:String):String
		{
			var array:Array = ogc_crs_urn.split(':');
			var prevToken:String = '';
			while (array.length > 2)
				prevToken = array.shift();
			var proj:String = array.join(':');
			var altProj:String = prevToken;
			if (array.length > 1)
				altProj += ':' + array[1];
			if (!WeaveAPI.ProjectionManager.projectionExists(proj) && WeaveAPI.ProjectionManager.projectionExists(altProj))
				proj = altProj;
			return proj;
		}
	}
}

import flash.geom.Point;
import flash.utils.getTimer;

import org.openscales.proj4as.Proj4as;
import org.openscales.proj4as.ProjPoint;
import org.openscales.proj4as.ProjProjection;

import weave.api.core.IDisposableObject;
import weave.api.data.ColumnMetadata;
import weave.api.data.DataType;
import weave.api.data.IAttributeColumn;
import weave.api.data.IColumnWrapper;
import weave.api.data.IProjector;
import weave.api.data.IQualifiedKey;
import weave.api.getLinkableDescendants;
import weave.api.newDisposableChild;
import weave.api.registerDisposableChild;
import weave.data.AttributeColumns.GeometryColumn;
import weave.data.AttributeColumns.ProxyColumn;
import weave.data.AttributeColumns.StreamedGeometryColumn;
import weave.data.ProjectionManager;
import weave.primitives.BLGNode;
import weave.primitives.GeneralizedGeometry;
import weave.primitives.GeometryType;
import weave.utils.BLGTreeUtils;
import weave.utils.ColumnUtils;
	
internal class WorkerThread implements IDisposableObject
{
	public function WorkerThread(projectionManager:ProjectionManager, unprojectedColumn:IAttributeColumn, destinationProjectionSRS:String)
	{
		registerDisposableChild(unprojectedColumn, this);
		this.projectionManager = projectionManager;
		this.unprojectedColumn = unprojectedColumn;
		this.destinationProjSRS = destinationProjectionSRS;
		this.reprojectedColumn = newDisposableChild(this, ProxyColumn);
		unprojectedColumn.addImmediateCallback(this, asyncStart, true);
	}
	
	public function dispose():void
	{
		projectionManager = null;
		unprojectedColumn = null;
		reprojectedColumn = null;
		destinationProjSRS = null;
	}
	
	// provides access to reprojected geometries
	public var reprojectedColumn:ProxyColumn;
	
	// values passed to the constructor -- these will not change.
	private var projectionManager:ProjectionManager;
	private var unprojectedColumn:IAttributeColumn;
	private var destinationProjSRS:String;
	
	// these values may change as the geometries are processed.
	private var prevTriggerCounter:uint = 0; // the ID of the current task, prevents old tasks from continuing
	private var keys:Array; // the keys in the unprojectedColumn
	private var values:Array; // the values in the unprojectedColumn
	private var numGeoms:int; // the total number of geometries to process
	private var keyIndex:int; // the index of the IQualifiedKey in the keys Array that needs to be processed
	private var coordsVectorIndex:int; // the index of the Array in coordsVector that should be passed to GeneralizedGeometry.setCoordinates()
	private var keysVector:Vector.<IQualifiedKey>; // vector to pass to GeometryColumn.setGeometries()
	private var geomVector:Vector.<GeneralizedGeometry>; // vector to pass to GeometryColumn.setGeometries()
	private const coordsVector:Vector.<Array> = new Vector.<Array>(); // each Array will be passed to setCoordinates() on the corresponding GeneralizedGeometry 
	private var sourceProj:ProjProjection; // parameter for Proj4as.transform()
	private var destinationProj:ProjProjection; // parameter for Proj4as.transform()

	// reusable temporary object
	private static const _tempProjPoint:ProjPoint = new ProjPoint();
	
	private function asyncStart():void
	{
		// if the source and destination projection are the same, we don't need to reproject.
		// if we don't know the projection of the original column, we can't reproject.
		// if there is no destination projection, don't reproject.
		var sourceProjSRS:String = unprojectedColumn.getMetadata(ColumnMetadata.PROJECTION);
		if (sourceProjSRS == destinationProjSRS ||
			!projectionManager.projectionExists(sourceProjSRS) ||
			!projectionManager.projectionExists(destinationProjSRS))
		{
			reprojectedColumn.delayCallbacks();
			reprojectedColumn.setMetadata(null);
			reprojectedColumn.setInternalColumn(unprojectedColumn);
			reprojectedColumn.resumeCallbacks();
			return; // done
		}
		
		// we need to reproject
		
		// if the internal column is the original column, create a new internal column because we don't want to overwrite the original
		if (reprojectedColumn.getInternalColumn() == null || reprojectedColumn.getInternalColumn() == unprojectedColumn)
		{
			reprojectedColumn.setInternalColumn(new GeometryColumn());
		}
		
		// set metadata on proxy column
		var metadata:Object = ColumnMetadata.getAllMetadata(unprojectedColumn);
		metadata[ColumnMetadata.DATA_TYPE] = DataType.GEOMETRY;
		metadata[ColumnMetadata.PROJECTION] = destinationProjSRS;
		reprojectedColumn.setMetadata(metadata);
		
		// wake up any columns such as ReferencedColumn that wait before registering child columns
		var streamedColumn:StreamedGeometryColumn = ColumnUtils.hack_findNonWrapperColumn(unprojectedColumn) as StreamedGeometryColumn;
		// try to find other internal StreamedGeometryColumn(s)
		var streamedColumns:Array = getLinkableDescendants(unprojectedColumn, StreamedGeometryColumn);
		if (streamedColumn)
			streamedColumns.unshift(streamedColumn);
		
		// Request the full unprojected detail because we don't know how much unprojected
		// detail we need to display the appropriate amount of reprojected detail.
		for each (streamedColumn in streamedColumns)
			streamedColumn.requestGeometryDetail(streamedColumn.collectiveBounds, 0);
		
		// if still downloading the tiles, do not reproject
		for each (streamedColumn in streamedColumns)
			if (streamedColumn.isStillDownloading())
				return; // done
		
		// initialize variables before calling processGeometries()
		keys = unprojectedColumn.keys; // all keys
		values = []; // all values
		numGeoms = 0;
		for (var i:int = 0; i < keys.length; i++)
		{
			var value:Array = unprojectedColumn.getValueFromKey(keys[i], Array) as Array;
			if (value)
				numGeoms += value.length;
			values.push(value);
		}
		keyIndex = 0;
		coordsVectorIndex = 0;
		keysVector = new Vector.<IQualifiedKey>();
		geomVector = new Vector.<GeneralizedGeometry>();
		coordsVector.length = 0;
		sourceProj = projectionManager.getProjection(sourceProjSRS);
		destinationProj = projectionManager.getProjection(destinationProjSRS);
		
		// ready to start iterating
		if (numGeoms == 0)
			asyncComplete();
		else
		{
			// TODO - assess priority assignment
			WeaveAPI.StageUtils.startTask(reprojectedColumn, asyncIterate, WeaveAPI.TASK_PRIORITY_NORMAL, asyncComplete, lang("Reprojecting {0} geometries in {1}", keys.length, debugId(unprojectedColumn)));
		}
	}
	
	/**
	 * This function will reproject the geometries in a column.
	 * @return A number between 0 and 1 indicating the progress.
	 */
	private function asyncIterate(stopTime:int):Number
	{
		while (getTimer() < stopTime)
		{
			// begin iteration
			if (keyIndex < keys.length)
			{
				// step 1: generate GeneralizedGeometry objects and project coordinates
				var key:IQualifiedKey = keys[keyIndex] as IQualifiedKey;
				var geomArray:Array = values[keyIndex] as Array;
				for (var geometryIndex:int = 0; geomArray && geometryIndex < geomArray.length; ++geometryIndex)
				{
					var oldGeometry:GeneralizedGeometry = geomArray[geometryIndex] as GeneralizedGeometry;
					if (!oldGeometry)
						continue;
					
					var geomParts:Vector.<Vector.<BLGNode>> = oldGeometry.getSimplifiedGeometry(); // no parameters = full list of vertices
					var geomIsPolygon:Boolean = oldGeometry.geomType == GeometryType.POLYGON;
	
					var newCoords:Array = [];
					var newGeometry:GeneralizedGeometry = new GeneralizedGeometry(oldGeometry.geomType);
					
					// fill newCoords array with reprojected coordinates
					for (var iPart:int = 0; iPart < geomParts.length; ++iPart)
					{
						if (iPart > 0)
						{
							// append part marker
							newCoords.push(NaN, NaN);
						}
						
						var part:Vector.<BLGNode> = geomParts[iPart];
						for (var iNode:int = 0; iNode < part.length; ++iNode)
						{
							var currentNode:BLGNode = part[iNode];
							
							_tempProjPoint.x = currentNode.x;
							_tempProjPoint.y = currentNode.y;
							_tempProjPoint.z = NaN; // this is important in case the projection reads the z value.
							if (Proj4as.transform(sourceProj, destinationProj, _tempProjPoint) == null)
								continue;
							
							var x:Number = _tempProjPoint.x;
							var y:Number = _tempProjPoint.y;
							// sometimes the reprojection may map a point to NaN.
							// if this occurs, we ignore the reprojected point because NaN is reserved as a marker for end of the part
							if (isNaN(x) || isNaN(y))
								continue;
							
							//if (!isFinite(_tempProjPoint.x) || !isFinite(_tempProjPoint.y))
							//	trace("point mapped to infinity");
							
							// save reproj coords
							newCoords.push(x, y);
						}
					}
					// indices in all vectors must match up
					keysVector.push(key);
					geomVector.push(newGeometry);
					// save coordinates for later processing
					coordsVector.push(newCoords);
				}
				keyIndex++;
			}
			else if (coordsVectorIndex < coordsVector.length)
			{
				// step 2: generate BLGTrees
				newGeometry = geomVector[coordsVectorIndex];
				newGeometry.setCoordinates(coordsVector[coordsVectorIndex], BLGTreeUtils.METHOD_SAMPLE);
				coordsVectorIndex++;
			}
			else
			{
				return 1;
			}
		}
		
		var progress:Number = (coordsVector.length + coordsVectorIndex) / (numGeoms + numGeoms);
		//trace('(',keyIndex,'+',coordsVectorIndex,') / (',keys.length,'+',coordsVector.length,') =',StandardLib.roundSignificant(progress, 2));
		return progress;
	}
	
	private function asyncComplete():void
	{
		reprojectedColumn.delayCallbacks()
		
		// after all geometries have been reprojected, update the reprojected column
		var geomColumn:GeometryColumn = reprojectedColumn.getInternalColumn() as GeometryColumn;
		if (geomColumn)
			geomColumn.setGeometries(keysVector, geomVector);
		
		reprojectedColumn.triggerCallbacks();
		reprojectedColumn.resumeCallbacks();
	}
}

internal class Projector implements IProjector
{
	public function Projector(source:ProjProjection, dest:ProjProjection)
	{
		this.source = source;
		this.dest = dest;
	}
	
	private var source:ProjProjection;
	private var dest:ProjProjection;
	private var tempProjPoint:ProjPoint = new ProjPoint();
	
	public function reproject(inputAndOutput:Point):Point
	{
		if (source == dest || !source || !dest)
			return inputAndOutput;
		
		tempProjPoint.x = inputAndOutput.x;
		tempProjPoint.y = inputAndOutput.y;
		tempProjPoint.z = NaN; // this is important in case the projection reads the z value.
		if (Proj4as.transform(source, dest, tempProjPoint))
		{
			inputAndOutput.x = tempProjPoint.x;
			inputAndOutput.y = tempProjPoint.y;
			return inputAndOutput;
		}

		inputAndOutput.x = NaN;
		inputAndOutput.y = NaN;
		return null;
	}
}

