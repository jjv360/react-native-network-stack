
package com.reactlibrary;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Dynamic;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.Callback;
import com.facebook.react.bridge.ReadableType;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadPoolExecutor;

import javax.annotation.Nullable;

/**
 * Interface to the JavaScript code.
 */
public class RNNetworkStackModule extends ReactContextBaseJavaModule {

    // Socket info
    class SocketInfo {
        Socket socket;
        ServerSocket server;
        ExecutorService readThread = Executors.newSingleThreadExecutor();
        ExecutorService writeThread = Executors.newSingleThreadExecutor();
    }

    // React context
    private final ReactApplicationContext reactContext;

    // Details of active sockets
    private final HashMap<Integer, SocketInfo> socketInfo = new HashMap<>();
    private static int nextSocketID = 0;

    public RNNetworkStackModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
    }

    @Override
    public String getName() {
        return "RNNetworkStack";
    }

    // Connects to a remote socket
    @ReactMethod public void tcpConnect(final String host, final int port, final Promise promise) {

        // Create socket info
        final SocketInfo si = new SocketInfo();

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Create socket
                    si.socket = new Socket(host, port);

                    // Store it and return ID
                    synchronized (socketInfo) {

                        // Store it
                        int id = nextSocketID++;
                        socketInfo.put(id, si);

                        // Create and return info
                        WritableMap map = Arguments.createMap();
                        map.putInt("id", id);
                        map.putInt("localPort", si.socket.getLocalPort());
                        map.putInt("remotePort", si.socket.getPort());
                        map.putString("localAddress", si.socket.getLocalAddress().toString());
                        map.putString("remoteAddress", si.socket.getInetAddress().toString());
                        promise.resolve(map);

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Reads data from the socket
    @ReactMethod public void tcpRead(final int id,
                                     final Dynamic terminator,
                                     final int maxLength,
                                     final String saveTo,
                                     final boolean skip,
                                     final String progressID,
                                     final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-not-found", "This socket is closed.");
            return;
        }

        // Get event emitter
        final DeviceEventManagerModule.RCTDeviceEventEmitter emitter = reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class);

        // Start a background operation
        si.readThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Check if still connected
                    if (si.socket == null)
                        throw new Exception("This socket is not connected.");

                    // Create output stream, depending on where the user wants to send the data
                    OutputStream output;
                    if (saveTo != null && !saveTo.isEmpty()) {

                        // User wants to write output to a file, create the output stream
                        File f = new File(saveTo);
                        output = new FileOutputStream(f);

                    } else {

                        // User wants the data
                        output = new ByteArrayOutputStream();

                    }

                    // Check how the data should be read
                    byte[] outputBuffer;
                    if (maxLength > -1) {

                        // Read specified amount of data
                        long lastUpdateTime = System.currentTimeMillis();
                        int amountRead = 0;
                        byte[] arr = new byte[1024*512];
                        while (amountRead < maxLength) {

                            // Read some data
                            int len = Math.min(arr.length, maxLength - amountRead);
                            len = si.socket.getInputStream().read(arr, 0, len);
                            if (len == -1)
                                throw new Exception("Socket closed before all data could be read.");

                            // Store it
                            output.write(arr, 0, len);
                            amountRead += len;

                            // Notify listener if needed
                            if (progressID != null && lastUpdateTime + 500 < System.currentTimeMillis()) {
                                lastUpdateTime = System.currentTimeMillis();
                                emitter.emit(progressID, amountRead);
                            }

                        }

                    } else if (terminator != null && terminator.getType() != ReadableType.Null) {

                        // User wants to read data until the specified terminator is found, convert terminator type to a byte array
                        byte[] terminatorData;
                        if (terminator.getType() == ReadableType.Number) {

                            // Terminator is a byte
                            int num = terminator.asInt();
                            if (num > 255)
                                throw new Exception("The byte specified as the terminator was too big.");

                            terminatorData = new byte[1];
                            terminatorData[0] = (byte) num;

                        } else if (terminator.getType() == ReadableType.String) {

                            // Terminator is a string, get UTF8 encoding
                            terminatorData = terminator.asString().getBytes("UTF-8");

                        } else {

                            // Unknown type!
                            throw new Exception("Unknown data type for 'until' parameter. Please specify a string or a byte.");

                        }

                        // Ensure we have some bytes in the terminator data
                        if (terminatorData.length == 0)
                            throw new Exception("Terminator was empty!");

                        // Read char by char until we have the desired terminator
                        int amountRead = 0;
                        int lastTerminatorMatch = 0;
                        long lastUpdateTime = System.currentTimeMillis();
                        while (true) {

                            // Read byte
                            int b = si.socket.getInputStream().read();
                            if (b == -1)
                                throw new Exception("Socket closed before all data could be read.");

                            // Check if this one matches our next desired terminator byte
                            if (terminatorData[lastTerminatorMatch] == b) {

                                // It does match, increase terminator index
                                lastTerminatorMatch += 1;
                                amountRead += 1;

                                // If all terminator bytes have been matched, stop
                                if (lastTerminatorMatch >= terminatorData.length)
                                    break;

                            } else {

                                // No match, put this char into main buffer
                                output.write(b);
                                amountRead += 1;

                                // Put any items we thought were part of the terminator, into the main buffer
                                for (int i = 0 ; i < lastTerminatorMatch ; i++)
                                    output.write(terminatorData[i]);

                                // Reset count
                                amountRead += lastTerminatorMatch;
                                lastTerminatorMatch = 0;

                            }

                            // Notify listener if needed
                            if (progressID != null && lastUpdateTime + 500 < System.currentTimeMillis()) {
                                lastUpdateTime = System.currentTimeMillis();
                                emitter.emit(progressID, amountRead);
                            }

                        }

                    } else {

                        // User didn't provide an end point for our data fetch, just fetch the first data that comes
                        byte[] bfr = new byte[1024*512];
                        int len = si.socket.getInputStream().read(bfr);
                        if (len == -1)
                            throw new Exception("Socket closed before any data could be read.");

                        // Put it into the output buffer
                        outputBuffer = new byte[len];
                        for (int i = 0 ; i < outputBuffer.length ; i++)
                            outputBuffer[i] = bfr[i];

                    }

                    // If the user is piping the data elsewhere, stop here
                    if (!ByteArrayOutputStream.class.isInstance(output)) {

                        // Done
                        promise.resolve(null);
                        return;

                    }

                    // TODO: Check how the user wants the output
                    if (true) {

                        // User wants UTF-8 encoded text
                        ByteArrayOutputStream buffer = (ByteArrayOutputStream) output;
                        promise.resolve(buffer.toString("UTF-8"));

                    } else {

                        // Can't figure out what type of data the user wants
                        throw new Exception("Unknown encoding type requested.");

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Writes data to the socket
    @ReactMethod public void tcpWrite(final int id,
                                      final Dynamic data,
                                      final boolean isFile,
                                      final String progressID,
                                      final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-not-found", "This socket is closed.");
            return;
        }

        // Get event emitter
        final DeviceEventManagerModule.RCTDeviceEventEmitter emitter = reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class);

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Check data type
                    if (isFile) {

                        // User wants to stream the specified file. Open it now.
                        File file = new File(data.asString());
                        FileInputStream fis = new FileInputStream(file);

                        // Start streaming it
                        long lastUpdateTime = System.currentTimeMillis();
                        int amountRead = 0;
                        byte[] buffer = new byte[1024*512];
                        while (true) {

                            // Read some data
                            int amt = fis.read(buffer);
                            if (amt == -1)
                                break;

                            // Write to socket
                            si.socket.getOutputStream().write(buffer, 0, amt);
                            amountRead += amt;

                            // Notify listener if needed
                            if (progressID != null && lastUpdateTime + 500 < System.currentTimeMillis()) {
                                lastUpdateTime = System.currentTimeMillis();
                                emitter.emit(progressID, amountRead);
                            }

                        }

                    } else if (data.getType() == ReadableType.Number) {

                        // User wants to send a single byte, check byte
                        int num = data.asInt();
                        if (num > 255)
                            throw new Exception("The byte specified was too big.");

                        // Send it
                        si.socket.getOutputStream().write(num);

                    } else if (data.getType() == ReadableType.String) {

                        // User wants to send a string, convert to UTF-8 and send it
                        byte[] bytes = data.asString().getBytes("UTF-8");
                        si.socket.getOutputStream().write(bytes);

                    } else {

                        // Unknown data type!
                        throw new Exception("Unknown data type specified.");

                    }

                    // Done
                    promise.resolve(null);

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Closes the socket
    @ReactMethod public void tcpClose(final int id,
                                      final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.resolve(null);
            return;
        }

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Close socket
                    if (si.socket != null && !si.socket.isClosed())
                        si.socket.close();

                    // Close server socket
                    if (si.server != null && !si.server.isClosed())
                        si.server.close();

                    // Remove it
                    synchronized (socketInfo) {
                        socketInfo.remove(id);
                    }

                    // Done
                    promise.resolve(null);

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Create a new server socket that listens on the specified port
    @ReactMethod public void tcpListen(final String host, final int port, final Promise promise) {

        // Create socket info
        final SocketInfo si = new SocketInfo();

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Create socket
                    si.server = new ServerSocket(port, 10, InetAddress.getByName(host));

                    // Store it and return ID
                    synchronized (socketInfo) {

                        // Store it
                        int id = nextSocketID++;
                        socketInfo.put(id, si);

                        // Create and return info
                        WritableMap map = Arguments.createMap();
                        map.putInt("id", id);
                        map.putInt("localPort", si.server.getLocalPort());
                        map.putString("localAddress", si.server.getInetAddress().toString());
                        promise.resolve(map);

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Accept an incoming connection
    @ReactMethod public void tcpAccept(final int id, final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket has been closed.");
            return;
        }

        // Start a background operation
        si.readThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Create new socket info
                    SocketInfo si2 = new SocketInfo();

                    // Get new socket
                    si2.socket = si.server.accept();
                    if (si2.socket == null)
                        throw new Exception("No incoming connection found.");

                    // Store it and return ID
                    synchronized (socketInfo) {

                        // Store it
                        int id = nextSocketID++;
                        socketInfo.put(id, si2);

                        // Create and return info
                        WritableMap map = Arguments.createMap();
                        map.putInt("id", id);
                        map.putInt("localPort", si2.socket.getLocalPort());
                        map.putInt("remotePort", si2.socket.getPort());
                        map.putString("localAddress", si2.socket.getLocalAddress().toString());
                        map.putString("remoteAddress", si2.socket.getInetAddress().toString());
                        promise.resolve(map);

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

}