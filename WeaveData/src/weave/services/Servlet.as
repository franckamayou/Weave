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
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	import flash.net.URLRequestHeader;
	import flash.net.URLRequestMethod;
	import flash.net.URLVariables;
	import flash.utils.ByteArray;
	import flash.utils.Dictionary;
	import flash.utils.getQualifiedClassName;
	
	import mx.core.mx_internal;
	import mx.rpc.AsyncToken;
	import mx.rpc.Fault;
	import mx.rpc.events.FaultEvent;
	import mx.rpc.events.ResultEvent;
	
	import weave.api.core.IDisposableObject;
	import weave.api.services.IAsyncService;
	import weave.utils.VectorUtils;
	
	/**
	 * This is an IAsyncService interface for a servlet that takes its parameters from URL variables.
	 * 
	 * @author adufilie
	 */	
	public class Servlet implements IAsyncService, IDisposableObject
	{
		public static const REQUEST_FORMAT_VARIABLES:String = URLLoaderDataFormat.VARIABLES;
		public static const REQUEST_FORMAT_BINARY:String = URLLoaderDataFormat.BINARY;
		
		/**
		 * @param servletURL The URL of the servlet (everything before the question mark in a URL request).
		 * @param methodParamName This is the name of the URL parameter that specifies the method to be called on the servlet.
		 * @param urlRequestDataFormat This is the format to use when sending parameters to the servlet.
		 */
		public function Servlet(servletURL:String, methodVariableName:String, urlRequestDataFormat:String)
		{
			if (urlRequestDataFormat != REQUEST_FORMAT_BINARY && urlRequestDataFormat != REQUEST_FORMAT_VARIABLES)
				throw new Error(getQualifiedClassName(Servlet) + ': urlRequestDataFormat not supported: "' + urlRequestDataFormat + '"');
			
			_servletURL = servletURL;
			_urlRequestDataFormat = urlRequestDataFormat;
			METHOD = methodVariableName;
		}
		
		/**
		 * The name of the property which contains the remote method name.
		 */
		private var METHOD:String = "method";
		/**
		 * The name of the property which contains method parameters.
		 */
		private var PARAMS:String = "params";
		/**
		 * The name of the property which specifies the index in the params Array that corresponds to an InputStream on the server side.
		 */
		private var STREAM_PARAM_INDEX:String = "streamParameterIndex";
		
		/**
		 * This is the base URL of the servlet.
		 * The base url is everything before the question mark in a url request like the following:
		 *     http://www.example.com/servlet?param=123
		 */
		public function get servletURL():String
		{
			return _servletURL;
		}
		protected var _servletURL:String;

		/**
		 * This is the data format of the results from HTTP GET requests.
		 */
		protected var _urlRequestDataFormat:String;
		
		/**
		 * This function makes a remote procedure call.
		 * @param methodName The name of the method to call.
		 * @param methodParameters The parameters to use when calling the method.
		 * @return An AsyncToken generated for the call.
		 */
		public function invokeAsyncMethod(methodName:String, methodParameters:Object = null):AsyncToken
		{
			var token:AsyncToken = new AsyncToken();
			
			_asyncTokenData[token] = arguments;
			
			if (!_invokeLater)
				invokeNow(token);
			
			return token;
		}
		
		/**
		 * This function may be overrided to give different servlet URLs for different methods.
		 * @param methodName The method.
		 * @return The servlet url for the method.
		 */
		protected function getServletURLForMethod(methodName:String):String
		{
			return _servletURL;
		}
		
		/**
		 * This will make a url request that was previously delayed.
		 * @param invokeToken An AsyncToken generated from a previous call to invokeAsyncMethod().
		 */
		protected function invokeNow(invokeToken:AsyncToken):void
		{
			var args:Array = _asyncTokenData[invokeToken] as Array;
			if (!args)
				return;
			
			var methodName:String = args[0];
			var methodParameters:Object = args[1];
			
			var request:URLRequest = new URLRequest(getServletURLForMethod(methodName));
			
			if (_urlRequestDataFormat == REQUEST_FORMAT_VARIABLES)
			{
				request.method = URLRequestMethod.GET;
				request.data = new URLVariables();
				
				// set url variable for the method name
				if (methodName)
					request.data[METHOD] = methodName;
				
				if (methodParameters != null)
				{
					// set url variables from parameters
					for (var name:String in methodParameters)
					{
						if (methodParameters[name] is Array)
							request.data[name] = WeaveAPI.CSVParser.createCSVRow(methodParameters[name]);
						else
							request.data[name] = methodParameters[name];
					}
				}
			}
			else if (_urlRequestDataFormat == REQUEST_FORMAT_BINARY)
			{
				request.method = URLRequestMethod.POST;
				request.requestHeaders = [new URLRequestHeader("Content-Type", "application/octet-stream")];
				// create object containing method name and parameters
				var obj:Object = new Object();
				obj[METHOD] = methodName;
				obj[PARAMS] = methodParameters;
				obj[STREAM_PARAM_INDEX] = -1; // index of stream parameter
				
				var streamContent:ByteArray = null;
				var params:Array = methodParameters as Array;
				if (params)
				{
					var index:int;
					for (index = 0; index < params.length; index++)
						if (params[index] is ByteArray)
							break;
					if (index < params.length)
					{
						obj[STREAM_PARAM_INDEX] = index; // tell the server about the stream parameter index
						streamContent = params[index];
						params[index] = null; // keep the placeholder where the server will insert the stream parameter
					}
				}
				
				// serialize into AMF3
				var byteArray:ByteArray = new ByteArray(); 
				byteArray.writeObject(obj);
				// if stream content exists, append after the AMF3-serialized object
				if (streamContent)
					byteArray.writeBytes(streamContent);
				
				request.data = byteArray;
			}
			
			// the last argument is BINARY instead of _dataFormat because the stream should not be parsed
			var token:AsyncToken = WeaveAPI.URLRequestUtils.getURL(this, request, URLLoaderDataFormat.BINARY);
			addAsyncResponder(token, resultHandler, faultHandler, invokeToken);
			_asyncTokenData[invokeToken] = token.loader;
		}
		
		/**
		 * Set this to true to prevent url requests from being made right away.
		 * When this is set to true, invokeNow() must be called to make delayed url requests.
		 * Setting this to false will immediately resume all delayed url requests.
		 */
		protected function set invokeLater(value:Boolean):void
		{
			_invokeLater = value;
			if (!_invokeLater)
				for (var token:Object in _asyncTokenData)
					invokeNow(token as AsyncToken);
		}
		
		protected function get invokeLater():Boolean
		{
			return _invokeLater;
		}
		
		private var _invokeLater:Boolean = false;
		
		/**
		 * Cancel a URLLoader request from a given AsyncToken.
		 * This function should be used with care because multiple requests for the same URL
		 * may all be cancelled by one client.
		 *  
		 * @param asyncToken The corresponding AsyncToken.
		 */		
		public function cancelLoaderFromToken(asyncToken:AsyncToken):void
		{
			var loader:URLLoader = _asyncTokenData[asyncToken] as URLLoader;
			
			if (loader)
				loader.close();
			
			delete _asyncTokenData[asyncToken];
		}
		
		/**
		 * This is a mapping of AsyncToken objects to URLLoader objects. 
		 * This mapping is necessary so a client with an AsyncToken can cancel the loader. 
		 */		
		private var _asyncTokenData:Dictionary = new Dictionary();
		
		private function resultHandler(event:ResultEvent, token:AsyncToken):void
		{
			if (_asyncTokenData[token] !== undefined)
			{
				token.mx_internal::applyResult(event);
				delete _asyncTokenData[token];
			}
		}
		
		private function faultHandler(event:FaultEvent, token:AsyncToken):void
		{
			if (_asyncTokenData[token] !== undefined)
			{
				token.mx_internal::applyFault(event);
				delete _asyncTokenData[token];
			}
		}
		
		public function dispose():void
		{
//			var fault:Fault = new Fault('Notification', 'Servlet was disposed', null);
			for each (var token:AsyncToken in VectorUtils.getKeys(_asyncTokenData))
			{
				cancelLoaderFromToken(token);
//				var event:FaultEvent = new FaultEvent(FaultEvent.FAULT, false, true, fault, token);
//				faultHandler(event, token);
			}
			_asyncTokenData = new Dictionary();
		}
	}
}
