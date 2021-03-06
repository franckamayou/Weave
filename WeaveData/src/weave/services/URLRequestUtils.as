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

package weave.services
{
	import flash.display.Loader;
	import flash.display.LoaderInfo;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.net.URLRequestMethod;
	import flash.utils.ByteArray;
	
	import mx.core.mx_internal;
	import mx.rpc.AsyncToken;
	import mx.rpc.Fault;
	import mx.rpc.events.FaultEvent;
	import mx.rpc.events.ResultEvent;
	import mx.utils.URLUtil;
	
	import weave.api.reportError;
	import weave.api.services.IURLRequestToken;
	import weave.api.services.IURLRequestUtils;
	import weave.compiler.StandardLib;
	import weave.utils.VectorUtils;

	/**
	 * An all-static class containing functions for downloading URLs.
	 * 
	 * @author adufilie
	 */
	public class URLRequestUtils implements IURLRequestUtils
	{
		public static var debug:Boolean = false;
		public static var delayResults:Boolean = false; // when true, delays result/fault handling and fills the 'delayed' Array.
		public static const delayed:Array = []; // array of objects with properties:  label:String, resume:Function
		
		public static const DATA_FORMAT_TEXT:String = URLLoaderDataFormat.TEXT;
		public static const DATA_FORMAT_BINARY:String = URLLoaderDataFormat.BINARY;
		public static const DATA_FORMAT_VARIABLES:String = URLLoaderDataFormat.VARIABLES;
		
		public static const LOCAL_FILE_URL_SCHEME:String = "local://";
		private var _baseURL:String;
		private var _localFiles:Object = {};
		
		/**
		 * This will set the base URL for use with relative URL requests.
		 */
		public function setBaseURL(baseURL:String):void
		{
			// only set baseURL if there is a ':' before first '/'
			if (baseURL.split('/')[0].indexOf(':') >= 0)
			{
				// remove '?' and everything after
				_baseURL = baseURL.split('?')[0];
			}
		}
		
		/**
		 * This will update a URLRequest to use the base URL specified via setBaseURL().
		 */
		private function addBaseURL(request:URLRequest):void
		{
			if (_baseURL)
				request.url = URLUtil.getFullURL(_baseURL, request.url);
		}
		
		/**
		 * @inheritDoc
		 */
		public function saveLocalFile(name:String, content:ByteArray):String
		{
			_localFiles[name] = content;
			var url:String = LOCAL_FILE_URL_SCHEME + name;
			var urlLoader:CustomURLLoader = _requestURLToLoader[url] as CustomURLLoader;
			if (urlLoader)
				urlLoader.applyResult(content);
			return url;
		}
		
		/**
		 * @inheritDoc
		 */
		public function getLocalFile(name:String):ByteArray
		{
			return _localFiles[name];
		}
		
		/**
		 * @inheritDoc
		 */
		public function removeLocalFile(name:String):void
		{
			delete _localFiles[name];
			var url:String = LOCAL_FILE_URL_SCHEME + name;
			var urlLoader:CustomURLLoader = _requestURLToLoader[url] as CustomURLLoader;
			if (urlLoader)
				urlLoader.applyFault(new Fault('FileError', lang('File removed: {0}', url)));
		}

		/**
		 * @inheritDoc
		 */
		public function getLocalFileNames():Array
		{
			var list:Array = VectorUtils.getKeys(_localFiles);
			StandardLib.sort(list);
			return list;
		}
		
		/**
		 * @inheritDoc
		 */
		public function getURL(relevantContext:Object, request:URLRequest, dataFormat:String = "binary", allowMultipleEvents:Boolean = false):AsyncToken
		{
			var urlLoader:CustomURLLoader;
			var fault:Fault;
			
			if (request.url.indexOf(LOCAL_FILE_URL_SCHEME) == 0)
			{
				var fileName:String = request.url.substr(LOCAL_FILE_URL_SCHEME.length);
				
				// If it's a local file, we still need to create a URLLoader.
				// CustomURLLoader doesn't load if the last parameter to the constructor is false.
				if (allowMultipleEvents)
					urlLoader = _requestURLToLoader[request.url] as CustomURLLoader;
				if (!urlLoader)
				{
					urlLoader = new CustomURLLoader(request, dataFormat, false);
					if (allowMultipleEvents)
						_requestURLToLoader[request.url] = urlLoader;
				}
				urlLoader.asyncToken.addRelevantContext(relevantContext);
				
				if (_localFiles.hasOwnProperty(fileName))
				{
					WeaveAPI.StageUtils.callLater(relevantContext, urlLoader.applyResult, [_localFiles[fileName]]);
				}
				else
				{
					fault = new Fault("Error", "Missing local file: " + fileName);
					WeaveAPI.StageUtils.callLater(relevantContext, urlLoader.applyFault, [fault]);
				}
				
				return urlLoader.asyncToken;
			}
			
			addBaseURL(request);
			
			// attempt to load crossdomain.xml from same folder as file
			//Security.loadPolicyFile(URLUtil.getFullURL(request.url, 'crossdomain.xml'));
			
			try
			{
				urlLoader = new CustomURLLoader(request, dataFormat, true);
			}
			catch (e:Error)
			{
				// When an error occurs, we need to run the asyncFaultHandler later
				// and return a new URLLoader. CustomURLLoader doesn't load if the 
				// last parameter to the constructor is false.
				urlLoader = new CustomURLLoader(request, dataFormat, false);
				
				fault = new Fault(String(e.errorID), e.name, e.message);
				fault.rootCause = e;
				WeaveAPI.StageUtils.callLater(relevantContext, urlLoader.applyFault, [fault]);
			}
			
			urlLoader.asyncToken.addRelevantContext(relevantContext);
			
			return urlLoader.asyncToken;
		}
		
		/**
		 * @inheritDoc
		 */
		public function getContent(relevantContext:Object, request:URLRequest, asyncResultHandler:Function = null, asyncFaultHandler:Function = null, token:Object = null, useCache:Boolean = true):IURLRequestToken
		{
			addBaseURL(request);
			
			if (useCache && request.method == URLRequestMethod.GET)
			{
				var content:Object = _contentCache[request.url];
				if (content)
				{
					// create a request token so its cancel function can be used and the result handler won't be called next frame
					var contentRequestToken:ContentAsyncResponder = new ContentAsyncResponder(relevantContext, null, asyncResultHandler, asyncFaultHandler, token);
					var resultEvent:ResultEvent = ResultEvent.createEvent(content);
					// wait one frame and make sure to call contentResult() instead of result().
					WeaveAPI.StageUtils.callLater(relevantContext, contentRequestToken.contentResult, [resultEvent]);
					return contentRequestToken;
				}
			}
			
			// check for a loader that is currently downloading this url
			var loader:CustomURLLoader = _requestURLToLoader[request.url] as CustomURLLoader;
			if (loader == null || loader.isClosed)
			{
				// make the request and add handler function that will load the content
				var customAsyncToken:CustomAsyncToken;
				if (useCache && _rawCache.hasOwnProperty(request.url))
				{
					loader = new CustomURLLoader(request, DATA_FORMAT_BINARY, false);
					customAsyncToken = loader.asyncToken;
					WeaveAPI.StageUtils.callLater(relevantContext, loader.applyResult, [_rawCache[request.url]]);
				}
				else
				{
					customAsyncToken = getURL(null, request, DATA_FORMAT_BINARY) as CustomAsyncToken;
					loader = customAsyncToken.loader as CustomURLLoader;
				}
				if (!loader)
					reportError('URLLoader missing from CustomAsyncToken', null, customAsyncToken);
				addAsyncResponder(customAsyncToken, handleGetContentResult, handleGetContentFault, request.url);
				_requestURLToLoader[request.url] = loader;
			}
			
			// create a ContentRequestToken so the handlers will run when the content finishes loading.
			return new ContentAsyncResponder(relevantContext, loader, asyncResultHandler, asyncFaultHandler, token);
		}
		
		/**
		 * Maps a URL to the raw ByteArray downloaded from a URL via getContent().
		 */
		private var _rawCache:Object = {};
		
		/**
		 * TEMPORARY SOLUTION
		 */
		public var saveCache:Boolean = false;
		
		/**
		 * @inheritDoc
		 */
		public function getCache():Object
		{
			return _rawCache;
		}
		
		/**
		 * @inheritDoc
		 */
		public function setCache(urlCache:Object):void
		{
			try
			{
				urlCache['']; // test if it's a dynamic object
				_rawCache = urlCache;
				saveCache = true;
			}
			catch (e:Error)
			{
				_rawCache = {};
				saveCache = false;
			}
		}
		
		/**
		 * This maps a URL to the content that was downloaded from that URL.
		 */
		private const _contentCache:Object = {};
		
		/**
		 * A mapping of URL Strings to CustomURLLoaders.
		 * This mapping is necessary for cached requests to return the active request.
		 */
		private const _requestURLToLoader:Object = {};
		
		/**
		 * This function gets called asynchronously from getContent().
		 * This function may cause both result & fault handlers to occur on original CustomURLLoader object,
		 * but it is ok because nothing outside this class has access to the internal CustomURLLoader
		 * and the result and fault functions added internally do not cause problems when both are called.
		 */
		private function handleGetContentResult(resultEvent:ResultEvent, url:String):void
		{
			var customURLLoader:CustomURLLoader = _requestURLToLoader[url] as CustomURLLoader;
			if (!customURLLoader)
				reportError('URLLoader missing in handleGetContentResult() for ' + url);
			
			var bytes:ByteArray = resultEvent.result as ByteArray;
			if (!bytes || bytes.length == 0)
			{
				var fault:Fault = new Fault("Error", "HTTP GET failed: Content is null from " + url);
				delete _requestURLToLoader[url];
				if (customURLLoader)
					customURLLoader.applyFault(fault);
				else
					reportError('Content is null and URLLoader is missing in handleGetContentResult() for ' + url);
				return;
			}
			
			_rawCache[url] = bytes;

			var handleLoaderComplete:Function = function (completeEvent:Event):void
			{
				var loaderInfo:LoaderInfo = completeEvent.target as LoaderInfo;
				var result:Object = loaderInfo.content;
				
				// save the image, run handler, and remove the loader from the dictionary
				_contentCache[url] = result;
				delete _requestURLToLoader[url];
				// run the responders from ContentRequestTokens that were not called before
				var responders:Array = customURLLoader ? customURLLoader.asyncToken.responders : [];
				var contentResultEvent:ResultEvent = ResultEvent.createEvent(result);
				for (var i:int = 0; i < responders.length; i++)
				{
					var contentRequestToken:ContentAsyncResponder = responders[i] as ContentAsyncResponder;
					if (contentRequestToken)
						contentRequestToken.contentResult(contentResultEvent);
				}
			};
			var handleLoaderError:Function = function(errorEvent:IOErrorEvent):void
			{
				var fault:Fault = new Fault(errorEvent.type, errorEvent.text + " (" + url + ")");
				delete _requestURLToLoader[url];
				if (customURLLoader)
					customURLLoader.applyFault(fault);
				else
					reportError('Received fault from content Loader; URLLoader is missing in handleGetContentResult() for ' + url);
			};
		
		
			//TODO:  loader spits out lots of errors when it can't parse the data as an image.
			
			var loader:Loader = new Loader();
			loader.contentLoaderInfo.addEventListener(Event.COMPLETE, handleLoaderComplete);
			loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, handleLoaderError);
			loader.loadBytes(bytes);
		}
		private function handleGetContentFault(faultEvent:FaultEvent, url:String):void
		{
			delete _requestURLToLoader[url];
		}
	}
}

import flash.events.ErrorEvent;
import flash.events.Event;
import flash.events.IOErrorEvent;
import flash.events.ProgressEvent;
import flash.events.SecurityErrorEvent;
import flash.net.URLLoader;
import flash.net.URLRequest;
import flash.utils.ByteArray;

import mx.core.mx_internal;
import mx.rpc.AsyncResponder;
import mx.rpc.AsyncToken;
import mx.rpc.Fault;
import mx.rpc.IResponder;
import mx.rpc.events.FaultEvent;
import mx.rpc.events.ResultEvent;
import mx.utils.ObjectUtil;

import weave.api.core.ILinkableObject;
import weave.api.services.IURLRequestToken;
import weave.compiler.StandardLib;
import weave.services.ExternalDownloader;
import weave.services.URLRequestUtils;

internal class CustomURLLoader extends URLLoader
{
	public function CustomURLLoader(request:URLRequest, dataFormat:String, loadNow:Boolean)
	{
		super.dataFormat = dataFormat;
		_urlRequest = request;
		_asyncToken = new CustomAsyncToken(this);
		
		if (loadNow)
		{
			if (URLRequestUtils.delayResults)
			{
				label = request.url;
				try
				{
					var bytes:ByteArray = ObjectUtil.copy(request.data as ByteArray) as ByteArray;
					bytes.uncompress();
					label += ' ' + ObjectUtil.toString(bytes.readObject()).split('\n').join(' ');
				}
				catch (e:Error) { }
				weaveTrace('requested ' + label);
				URLRequestUtils.delayed.push({"label": label, "resume": resume});
			}
			
			if (failedHosts[getHost()] && JavaScript.available)
			{
				// don't bother trying a URLLoader with the same host that previously failed due to a security error
				ExternalDownloader.download(_urlRequest, dataFormat, _asyncToken);
				return;
			}
			
			// set up event listeners
			addEventListener(Event.COMPLETE, handleGetResult);
			addEventListener(IOErrorEvent.IO_ERROR, handleGetError);
			addEventListener(SecurityErrorEvent.SECURITY_ERROR, handleSecurityError);
			addEventListener(ProgressEvent.PROGRESS, handleProgressUpdate);
			
			if (URLRequestUtils.debug)
				trace(debugId(this), 'request', request.url);
			
			//WeaveAPI.StageUtils.callLater(null, loadLater);
			super.load(request);
		}
	}
	
	private function loadLater():void
	{
		if (!_isClosed)
			super.load(_urlRequest);
	}
	
	/**
	 * Lookup for hosts that previously failed due to crossdomain.xml security error
	 */
	private static const failedHosts:Object = {}; // host -> true
	private function getHost():String
	{
		var url:String = _urlRequest.url;
		var start:int = url.indexOf("/") + 2;
		var length:int = url.indexOf("/", start);
		var host:String = url.substr(0, length);
		return host;
	}
	
	internal var label:String;
	private var _asyncToken:CustomAsyncToken;
	private var _isClosed:Boolean = false;
	private var _urlRequest:URLRequest = null;
	
	override public function load(request:URLRequest):void
	{
		throw new Error("URLLoaders from URLRequestUtils are not to be reused.");
	}
	
	override public function close():void
	{
		WeaveAPI.ProgressIndicator.removeTask(_asyncToken);
		if (URLRequestUtils.debug)
			trace(debugId(this), 'cancel', _urlRequest.url);
		_isClosed = true;
		try {
			super.close();
		} catch (e:Error) { } // ignore close() errors
	}
	
	/**
	 * This is the AsyncToken that keeps track of IResponders.
	 */	
	public function get asyncToken():CustomAsyncToken
	{
		return _asyncToken;
	}
	
	/**
	 * This is the URLRequest that was passed to load().
	 */
	public function get urlRequest():URLRequest
	{
		return _urlRequest;
	}
	
	/**
	 * Gets the open or closed status of the URLLoader.
	 */
	public function get isClosed():Boolean
	{
		return _isClosed;
	}
	
	/**
	 * This provides a convenient way for adding result/fault handlers.
	 * @param responder
	 */
	public function addResponder(responder:IResponder):void
	{
		_asyncToken.addResponder(responder);
	}
	
	/**
	 * This provides a convenient way to remove a URLRequestToken as a responder.
	 * @param responder
	 */
	public function removeResponder(responder:CustomAsyncResponder):void
	{
		var responders:Array = _asyncToken.responders;
		var index:int = responders.indexOf(responder);
		if (index >= 0)
		{
			// URLRequestToken found -- remove it
			responders.splice(index, 1);
			// see if there are any more URLRequestTokens
			for each (var obj:Object in _asyncToken.responders)
				if (obj is CustomAsyncResponder)
					return;
			// no more CustomAsyncResponders found, so cancel
			close();
		}
	}

	private function handleProgressUpdate(event:Event):void
	{
		if (WeaveAPI.ProgressIndicator.hasTask(_asyncToken))
			WeaveAPI.ProgressIndicator.updateTask(_asyncToken, bytesLoaded / bytesTotal);
	}

	private var _resumeFunc:Function = null;
	private var _resumeParam:Object = null;
	/**
	 * When URLRequestUtils.delayResults is set to true, this function will resume
	 * @return true  
	 */	
	public function resume():void
	{
		if (_resumeFunc == null)
		{
			_resumeFunc = resume; // this cancels the pending delay behavior
		}
		else if (_resumeFunc != resume)
		{
			_resumeFunc(_resumeParam);
		}
	}
	
	/**
	 * This function gets called when a URLLoader generated by getURL() dispatches a COMPLETE Event.
	 * @param event The COMPLETE Event from a URLLoader.
	 */
	private function handleGetResult(event:Event):void
	{
		if (URLRequestUtils.debug)
			trace(debugId(this), 'complete', _urlRequest.url);
		//WeaveAPI.externalTrace('getResult ' + label);
		if (URLRequestUtils.delayResults && _resumeFunc == null)
		{
			_resumeFunc = handleGetResult;
			_resumeParam = event;
			return;
		}
		
		// broadcast result to responders
		WeaveAPI.StageUtils.callLater(null, applyResult, [data]);
		//applyResult(data);
	
	}
	
	private function fixErrorMessage(errorEvent:ErrorEvent):void
	{
		var text:String = errorEvent.text;
		// If the user is running the non-debugger version of Flash Player, provide the same info the debugger version would provide.
		if (text == "Error #2048")
			text += StandardLib.substitute(": Security sandbox violation: {0} cannot load data from {1}", WeaveAPI.topLevelApplication.url, urlRequest.url);
		if (text == "Error #2032")
			text += ": Stream Error. URL: " + urlRequest.url;
		errorEvent.text = text;
	}
	
	/**
	 * This function gets called when a URLLoader generated by getURL() dispatches an IOErrorEvent.
	 * @param event The ErrorEvent from a URLLoader.
	 */
	private function handleGetError(event:Event):void
	{
		if (URLRequestUtils.debug)
			trace(debugId(this), 'error', _urlRequest.url);
		if (URLRequestUtils.delayResults && _resumeFunc == null)
		{
			_resumeFunc = handleGetError;
			_resumeParam = event;
			return;
		}
		
		// broadcast fault to responders
		var fault:Fault;
		var errorEvent:ErrorEvent = event as ErrorEvent;
		if (errorEvent)
		{
			fixErrorMessage(errorEvent);
			fault = new Fault(event.type, event.type, errorEvent.text);
		}
		else
			fault = new Fault(event.type, event.type, "Request cancelled");
		fault.rootCause = this;
		applyFault(fault);
		_isClosed = true;
	}
	
	/**
	 * This function gets called when a URLLoader generated by get() dispatches an SecurityErrorEvent.
	 * @param event The ErrorEvent from a URLLoader.
	 */
	private function handleSecurityError(event:SecurityErrorEvent):void
	{
		fixErrorMessage(event);
		if (JavaScript.available)
		{
			// Server did not have a permissive crossdomain.xml, so try JavaScript/CORS
			failedHosts[getHost()] = true;
			ExternalDownloader.download(_urlRequest, dataFormat, _asyncToken);
		}
		else
		{
			handleGetError(event);
		}
	}
	
	internal function applyResult(data:Object):void
	{
		if (this.data !== data)
			this.data = data;
		_asyncToken.mx_internal::applyResult(ResultEvent.createEvent(data));
	}
	
	internal function applyFault(fault:Fault):void
	{
		_asyncToken.mx_internal::applyFault(FaultEvent.createEvent(fault));
	}
}

internal class CustomAsyncToken extends AsyncToken
{
	public function CustomAsyncToken(loader:CustomURLLoader)
	{
		_loader = loader;
		addResponder(new AsyncResponder(firstResponder, firstResponder));
	}
	
	private var _loader:CustomURLLoader;
	private var relevantContexts:Array = [];
	
	public function get loader():CustomURLLoader
	{
		return _loader;
	}
	
	/**
	 * Adds a context in which this AsyncToken is relevant.
	 * If all contexts are disposed, this AsyncToken will not broadcast a ResultEvent or FaultEvent.
	 */
	public function addRelevantContext(context:Object):void
	{
		var desc:String = "URL request";
		if (loader)
			desc += ": " + loader.urlRequest.url;
		WeaveAPI.ProgressIndicator.addTask(this, context as ILinkableObject, desc);
		relevantContexts.push(context);
	}
	
	private function contextDisposed(context:Object, i:int, a:Array):Boolean
	{
		return WeaveAPI.SessionManager.objectWasDisposed(context);
	}
	
	private function firstResponder(event:Event, token:Object):void
	{
		WeaveAPI.ProgressIndicator.removeTask(this);
		// if there are contexts and none are relevant, don't call responders
		if (relevantContexts.length && relevantContexts.every(contextDisposed))
			super.responders.length = 0;
	}
}

/**
 * This is an AsyncResponder that can be cancelled using the IURLRequestToken interface.
 * 
 * @author adufilie
 */
internal class CustomAsyncResponder extends AsyncResponder implements IURLRequestToken
{
	public function CustomAsyncResponder(relevantContext:Object, loader:CustomURLLoader, result:Function, fault:Function, token:Object = null)
	{
		super(result || noOp, fault || noOp, token);
		
		this.relevantContext = relevantContext;
		
		this.loader = loader;
		if (loader)
			loader.addResponder(this);
		
		WeaveAPI.ProgressIndicator.addTask(this, relevantContext as ILinkableObject);
	}
	
	private static function noOp(..._):void {} // does nothing
	
	private var loader:CustomURLLoader;
	private var relevantContext:Object;
	
	public function cancelRequest():void
	{
		WeaveAPI.ProgressIndicator.removeTask(this);
		if (loader && !WeaveAPI.SessionManager.objectWasDisposed(this))
			loader.removeResponder(this);
		WeaveAPI.SessionManager.disposeObject(this);
	}
	
	override public function result(data:Object):void
	{
		WeaveAPI.ProgressIndicator.removeTask(this);
		if (!WeaveAPI.SessionManager.objectWasDisposed(this) && !WeaveAPI.SessionManager.objectWasDisposed(relevantContext))
			super.result(data);
	}
	
	override public function fault(data:Object):void
	{
		WeaveAPI.ProgressIndicator.removeTask(this);
		if (!WeaveAPI.SessionManager.objectWasDisposed(this) && !WeaveAPI.SessionManager.objectWasDisposed(relevantContext))
			super.fault(data);
	}
}

/**
 * This is a CustomAsyncResponder that is used by getContent() to delay the handlers until the content finishes loading.
 * 
 * @author adufilie
 */
internal class ContentAsyncResponder extends CustomAsyncResponder
{
	public function ContentAsyncResponder(relevantContext:Object, loader:CustomURLLoader, result:Function, fault:Function, token:Object = null)
	{
		super(relevantContext, loader, result, fault, token);
	}
	
	/**
	 * This function should be called when the content is loaded.
	 * @param event
	 */	
	internal function contentResult(event:ResultEvent):void
	{
		super.result(event);
	}
	
	/**
	 * This function does nothing.  Instead, contentResult() should be called.
	 * @param data
	 */
	override public function result(data:Object):void
	{
		// Instead of this function, contentResult() will call super.result()
	}
}
