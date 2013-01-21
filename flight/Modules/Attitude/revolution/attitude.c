/**
 ******************************************************************************
 * @addtogroup OpenPilotModules OpenPilot Modules
 * @{
 * @addtogroup Attitude Copter Control Attitude Estimation
 * @brief Acquires sensor data and computes attitude estimate
 * Specifically updates the the @ref AttitudeActual "AttitudeActual" and @ref AttitudeRaw "AttitudeRaw" settings objects
 * @{
 *
 * @file       attitude.c
 * @author     The OpenPilot Team, http://www.openpilot.org Copyright (C) 2010.
 * @author     Tau Labs, http://taulabs.org Copyright (C) 2012-2013.
 * @brief      Module to handle attitude estimation on the pro systems.
 *
 * @see        The GNU Public License (GPL) Version 3
 *
 ******************************************************************************/
/*
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
 */

/**
 * Input objects: None, takes sensor data via pios
 * Output objects: @ref AttitudeRaw @ref AttitudeActual
 *
 * This module computes an attitude estimate from the sensor data
 *
 * The module executes in its own thread.
 *
 * UAVObjects are automatically generated by the UAVObjectGenerator from
 * the object definition XML file.
 *
 * Modules have no API, all communication to other modules is done through UAVObjects.
 * However modules may use the API exposed by shared libraries.
 * See the OpenPilot wiki for more details.
 * http://www.openpilot.org/OpenPilot_Application_Architecture
 *
 */

#include "pios.h"
#include "openpilot.h"

#include "accels.h"
#include "attitudeactual.h"
#include "attitudesettings.h"
#include "baroaltitude.h"
#include "flightstatus.h"
#include "gpsposition.h"
#include "gpsvelocity.h"
#include "gyros.h"
#include "gyrosbias.h"
#include "homelocation.h"
#include "inertialsensorsettings.h"
#include "inssettings.h"
#include "magnetometer.h"
#include "nedposition.h"
#include "positionactual.h"
#include "revosettings.h"
#include "velocityactual.h"
#include "CoordinateConversions.h"

// Private constants
#define STACK_SIZE_BYTES 2048
#define TASK_PRIORITY (tskIDLE_PRIORITY+3)
#define FAILSAFE_TIMEOUT_MS 10

#define F_PI 3.14159265358979323846f
#define PI_MOD(x) (fmodf(x + F_PI, F_PI * 2) - F_PI)

// low pass filter configuration to calculate offset
// of barometric altitude sensor
// reasoning: updates at: 10 Hz, tau= 300 s settle time
// exp(-(1/f) / tau ) ~=~ 0.9997
#define BARO_OFFSET_LOWPASS_ALPHA 0.9997f 

// Private types

//! Structure containing the information to zero the gyros
struct gyro_bias_estimation {
	float      accumulated_gyro[3];
	uint32_t   accumulated_gyro_samples;
	bool       accumulating_gyro;
};

// Private variables
static xTaskHandle attitudeTaskHandle;

static xQueueHandle gyroQueue;
static xQueueHandle accelQueue;
static xQueueHandle magQueue;
static xQueueHandle baroQueue;
static xQueueHandle gpsQueue;
static xQueueHandle gpsVelQueue;

static AttitudeSettingsData attitudeSettings;
static HomeLocationData homeLocation;
static INSSettingsData insSettings;
static RevoSettingsData revoSettings;
static bool gyroBiasSettingsUpdated = false;
const uint32_t SENSOR_QUEUE_SIZE = 10;

bool accel_filter_enabled;
float accel_alpha;

static struct gyro_bias_estimation gyro_bias_estimation;

// Private functions
static void AttitudeTask(void *parameters);

static int32_t updateAttitudeComplementary(bool first_run);
static int32_t updateAttitudeINSGPS(bool first_run, bool outdoor_mode);
static void settingsUpdatedCb(UAVObjEvent * objEv);

//! A low pass filter on the accels which helps with vibration resistance
static void apply_accel_filter(const float * raw, float * filtered);
static int32_t getNED(GPSPositionData * gpsPosition, float * NED);

//! Compute the mean gyro accumulated and assign the bias
static void accumulate_gyro_compute();

//! Zero the gyro accumulators
static void accumulate_gyro_zero();

//! Store a gyro sample
static void accumulate_gyro(GyrosData *gyrosData);

/**
 * API for sensor fusion algorithms:
 * Configure(xQueueHandle gyro, xQueueHandle accel, xQueueHandle mag, xQueueHandle baro)
 *   Stores all the queues the algorithm will pull data from
 * FinalizeSensors() -- before saving the sensors modifies them based on internal state (gyro bias)
 * Update() -- queries queues and updates the attitude estiamte
 */


/**
 * Initialise the module.  Called before the start function
 * \returns 0 on success or -1 if initialisation failed
 */
int32_t AttitudeInitialize(void)
{
	AttitudeActualInitialize();
	AttitudeSettingsInitialize();
	InertialSensorSettingsInitialize();
	INSSettingsInitialize();
	NEDPositionInitialize();
	PositionActualInitialize();
	RevoSettingsInitialize();
	VelocityActualInitialize();

	// Initialize this here while we aren't setting the homelocation in GPS
	HomeLocationInitialize();

	AttitudeSettingsConnectCallback(&settingsUpdatedCb);
	HomeLocationConnectCallback(&settingsUpdatedCb);
	InertialSensorSettingsConnectCallback(&settingsUpdatedCb);
	INSSettingsConnectCallback(&settingsUpdatedCb);
	RevoSettingsConnectCallback(&settingsUpdatedCb);

	return 0;
}

/**
 * Start the task.  Expects all objects to be initialized by this point.
 * \returns 0 on success or -1 if initialisation failed
 */
int32_t AttitudeStart(void)
{
	// Create the queues for the sensors
	gyroQueue = xQueueCreate(1, sizeof(UAVObjEvent));
	accelQueue = xQueueCreate(1, sizeof(UAVObjEvent));
	magQueue = xQueueCreate(2, sizeof(UAVObjEvent));
	baroQueue = xQueueCreate(1, sizeof(UAVObjEvent));
	gpsQueue = xQueueCreate(1, sizeof(UAVObjEvent));
	gpsVelQueue = xQueueCreate(1, sizeof(UAVObjEvent));

	// Initialize quaternion
	AttitudeActualData attitude;
	AttitudeActualGet(&attitude);
	attitude.q1 = 1;
	attitude.q2 = 0;
	attitude.q3 = 0;
	attitude.q4 = 0;
	AttitudeActualSet(&attitude);

	// Cannot trust the values to init right above if BL runs
	GyrosBiasData gyrosBias;
	GyrosBiasGet(&gyrosBias);
	gyrosBias.x = 0;
	gyrosBias.y = 0;
	gyrosBias.z = 0;
	GyrosBiasSet(&gyrosBias);

	GyrosConnectQueue(gyroQueue);
	AccelsConnectQueue(accelQueue);
	if (MagnetometerHandle())
		MagnetometerConnectQueue(magQueue);
	if (BaroAltitudeHandle())
		BaroAltitudeConnectQueue(baroQueue);
	if (GPSPositionHandle())
		GPSPositionConnectQueue(gpsQueue);
	if (GPSVelocityHandle())
		GPSVelocityConnectQueue(gpsVelQueue);

	// Start main task
	xTaskCreate(AttitudeTask, (signed char *)"Attitude", STACK_SIZE_BYTES/4, NULL, TASK_PRIORITY, &attitudeTaskHandle);
	TaskMonitorAdd(TASKINFO_RUNNING_ATTITUDE, attitudeTaskHandle);
	PIOS_WDG_RegisterFlag(PIOS_WDG_ATTITUDE);

	return 0;
}

MODULE_INITCALL(AttitudeInitialize, AttitudeStart)

/**
 * Module thread, should not return.
 */
static void AttitudeTask(void *parameters)
{
	bool first_run = true;
	uint32_t last_algorithm;
	AlarmsClear(SYSTEMALARMS_ALARM_ATTITUDE);

	// Force settings update to make sure rotation loaded
	settingsUpdatedCb(NULL);

	// Wait for all the sensors be to read
	vTaskDelay(100);

	// Invalidate previous algorithm to trigger a first run
	last_algorithm = 0xfffffff;

	// Main task loop
	while (1) {

		int32_t ret_val = -1;

		if (last_algorithm != revoSettings.FusionAlgorithm) {
			last_algorithm = revoSettings.FusionAlgorithm;
			first_run = true;
		}

		// This  function blocks on data queue
		switch (revoSettings.FusionAlgorithm ) {
			case REVOSETTINGS_FUSIONALGORITHM_COMPLEMENTARY:
				ret_val = updateAttitudeComplementary(first_run);
				break;
			case REVOSETTINGS_FUSIONALGORITHM_INSOUTDOOR:
				ret_val = updateAttitudeINSGPS(first_run, true);
				break;
			case REVOSETTINGS_FUSIONALGORITHM_INSINDOOR:
				ret_val = updateAttitudeINSGPS(first_run, false);
				break;
			default:
				AlarmsSet(SYSTEMALARMS_ALARM_ATTITUDE,SYSTEMALARMS_ALARM_CRITICAL);
				break;
		}

		if(ret_val == 0)
			first_run = false;

		PIOS_WDG_UpdateFlag(PIOS_WDG_ATTITUDE);
	}
}

float accel_mag;
float qmag;
float attitudeDt;
float mag_err[3];
float magKi = 0.000001f;

static int32_t updateAttitudeComplementary(bool first_run)
{
	UAVObjEvent ev;
	GyrosData gyrosData;
	AccelsData accelsData;
	static int32_t timeval;
	float dT;

	static float accels_filtered[3] = {0,0,0};
	static float grot_filtered[3] = {0,0,0};

	static uint32_t arming_count = 0;

	// Track the initialization state of the complimentary filter
	static enum complimentary_filter_status {
		CF_POWERON,
		CF_INITIALIZING,
		CF_ARMING,
		CF_NORMAL
	} complimentary_filter_status = CF_POWERON;

	// Wait until the accel and gyro object is updated, if a timeout then go to failsafe
	if ( xQueueReceive(gyroQueue, &ev, FAILSAFE_TIMEOUT_MS / portTICK_RATE_MS) != pdTRUE ||
	     xQueueReceive(accelQueue, &ev, 1 / portTICK_RATE_MS) != pdTRUE )
	{
		// When one of these is updated so should the other
		// Do not set attitude timeout warnings in simulation mode
		if (!AttitudeActualReadOnly()){
			AlarmsSet(SYSTEMALARMS_ALARM_ATTITUDE,SYSTEMALARMS_ALARM_WARNING);
			return -1;
		}
	}

	AccelsGet(&accelsData);

	// When this algorithm is first run force it to a known condition
	if(first_run) {
		MagnetometerData magData;
		magData.x = 100;
		magData.y = 0;
		magData.z = 0;

		// Wait for a mag reading if a magnetometer was registered
		if (PIOS_SENSORS_GetQueue(PIOS_SENSOR_MAG) != NULL) {
			if ( xQueueReceive(magQueue, &ev, 0 / portTICK_RATE_MS) != pdTRUE ) {
				return -1;
			}
			MagnetometerGet(&magData);
		}

		// Pick initial attitude based on accel and mag data
		AttitudeActualData attitudeActual;
		AttitudeActualGet(&attitudeActual);
		attitudeActual.Roll = atan2f(-accelsData.y, -accelsData.z) * 180.0f / F_PI;
		attitudeActual.Pitch = atan2f(accelsData.x, -accelsData.z) * 180.0f / F_PI;
		attitudeActual.Yaw = atan2f(-magData.y, magData.x) * 180.0f / F_PI;
		RPY2Quaternion(&attitudeActual.Roll,&attitudeActual.q1);
		AttitudeActualSet(&attitudeActual);

		complimentary_filter_status = CF_POWERON;
		timeval = PIOS_DELAY_GetRaw();

		arming_count = 0;

		return 0;
	}

	FlightStatusData flightStatus;
	FlightStatusGet(&flightStatus);

	if (complimentary_filter_status == CF_POWERON) {
		complimentary_filter_status = (xTaskGetTickCount() > 1000) ?
			CF_INITIALIZING : CF_POWERON;
	} else if(complimentary_filter_status == CF_INITIALIZING &&
		(xTaskGetTickCount() < 7000) && 
		(xTaskGetTickCount() > 1000)) {

		// For first 7 seconds use accels to get gyro bias
		attitudeSettings.AccelKp = 0.1f + 0.1f * (xTaskGetTickCount() < 4000);
		attitudeSettings.AccelKi = 0.1f;
		attitudeSettings.YawBiasRate = 0.1f;
		attitudeSettings.MagKp = 0.1f;
	} else if ((attitudeSettings.ZeroDuringArming == ATTITUDESETTINGS_ZERODURINGARMING_TRUE) && 
	           (flightStatus.Armed == FLIGHTSTATUS_ARMED_ARMING)) {

		// Use a rapidly decrease accelKp to force the attitude to snap back
		// to level and then converge more smoothly
		if (arming_count < 20)
			attitudeSettings.AccelKp = 1.0f;
		else if (attitudeSettings.AccelKp > 0.1f)
			attitudeSettings.AccelKp -= 0.01f;
		arming_count++;

		// Set the other parameters to drive faster convergence
		attitudeSettings.AccelKi = 0.1f;
		attitudeSettings.YawBiasRate = 0.1f;
		attitudeSettings.MagKp = 0.1f;

		// Don't apply LPF to the accels during arming
		accel_filter_enabled = false;

		// Indicate arming so that after arming it reloads
		// the normal settings
		if (complimentary_filter_status != CF_ARMING) {
			accumulate_gyro_zero();
			complimentary_filter_status = CF_ARMING;
			gyro_bias_estimation.accumulating_gyro = true;
		}

	} else if (complimentary_filter_status == CF_ARMING ||
	           complimentary_filter_status == CF_INITIALIZING) {

		AttitudeSettingsGet(&attitudeSettings);
		if(accel_alpha > 0.0f)
			accel_filter_enabled = true;

		// If arming that means we were accumulating gyro
		// samples.  Compute new bias.
		if (complimentary_filter_status == CF_ARMING) {
			accumulate_gyro_compute();
			gyro_bias_estimation.accumulating_gyro = false;
			arming_count = 0;
		}

		// Indicate normal mode to prevent rerunning this code
		complimentary_filter_status = CF_NORMAL;
	}

	GyrosGet(&gyrosData);
	accumulate_gyro(&gyrosData);

	// Compute the dT using the cpu clock
	dT = PIOS_DELAY_DiffuS(timeval) / 1000000.0f;
	timeval = PIOS_DELAY_GetRaw();

	float q[4];

	AttitudeActualData attitudeActual;
	AttitudeActualGet(&attitudeActual);

	float grot[3];
	float accel_err[3];

	// Get the current attitude estimate
	quat_copy(&attitudeActual.q1, q);

	// Apply smoothing to accel values, to reduce vibration noise before main calculations.
	apply_accel_filter(&accelsData.x,accels_filtered);

	// Rotate gravity to body frame and cross with accels
	grot[0] = -(2 * (q[1] * q[3] - q[0] * q[2]));
	grot[1] = -(2 * (q[2] * q[3] + q[0] * q[1]));
	grot[2] = -(q[0] * q[0] - q[1]*q[1] - q[2]*q[2] + q[3]*q[3]);
	CrossProduct((const float *) &accelsData.x, (const float *) grot, accel_err);

	// Apply same filtering to the rotated attitude to match delays
	apply_accel_filter(grot,grot_filtered);

	// Compute the error between the predicted direction of gravity and smoothed acceleration
	CrossProduct((const float *) accels_filtered, (const float *) grot_filtered, accel_err);

	float grot_mag;
	if (accel_filter_enabled)
		grot_mag = sqrtf(grot_filtered[0]*grot_filtered[0] + grot_filtered[1]*grot_filtered[1] + grot_filtered[2]*grot_filtered[2]);
	else
		grot_mag = 1.0f;

	// Account for accel magnitude
	accel_mag = accels_filtered[0]*accels_filtered[0] + accels_filtered[1]*accels_filtered[1] + accels_filtered[2]*accels_filtered[2];
	accel_mag = sqrtf(accel_mag);
	if (grot_mag > 1.0e-3f && accel_mag > 1.0e-3f) {
		accel_err[0] /= (accel_mag * grot_mag);
		accel_err[1] /= (accel_mag * grot_mag);
		accel_err[2] /= (accel_mag * grot_mag);
	} else {
		accel_err[0] = 0;
		accel_err[1] = 0;
		accel_err[2] = 0;
	}

	if ( xQueueReceive(magQueue, &ev, 0) != pdTRUE )
	{
		// Rotate gravity to body frame and cross with accels
		float brot[3];
		float Rbe[3][3];
		MagnetometerData mag;
		
		Quaternion2R(q, Rbe);
		MagnetometerGet(&mag);

		// If the mag is producing bad data don't use it (normally bad calibration)
		if  (mag.x == mag.x && mag.y == mag.y && mag.z == mag.z &&
			 homeLocation.Set == HOMELOCATION_SET_TRUE) {
			rot_mult(Rbe, homeLocation.Be, brot, false);

			float mag_len = sqrtf(mag.x * mag.x + mag.y * mag.y + mag.z * mag.z);
			mag.x /= mag_len;
			mag.y /= mag_len;
			mag.z /= mag_len;

			float bmag = sqrtf(brot[0] * brot[0] + brot[1] * brot[1] + brot[2] * brot[2]);
			brot[0] /= bmag;
			brot[1] /= bmag;
			brot[2] /= bmag;

			// Only compute if neither vector is null
			if (bmag < 1 || mag_len < 1)
				mag_err[0] = mag_err[1] = mag_err[2] = 0;
			else
				CrossProduct((const float *) &mag.x, (const float *) brot, mag_err);
		}
	} else {
		mag_err[0] = mag_err[1] = mag_err[2] = 0;
	}

	// Accumulate integral of error.  Scale here so that units are (deg/s) but Ki has units of s
	GyrosBiasData gyrosBias;
	GyrosBiasGet(&gyrosBias);
	gyrosBias.x -= accel_err[0] * attitudeSettings.AccelKi;
	gyrosBias.y -= accel_err[1] * attitudeSettings.AccelKi;
	gyrosBias.z -= mag_err[2] * magKi;
	GyrosBiasSet(&gyrosBias);

	// Correct rates based on error, integral component dealt with in updateSensors
	gyrosData.x += accel_err[0] * attitudeSettings.AccelKp / dT;
	gyrosData.y += accel_err[1] * attitudeSettings.AccelKp / dT;
	gyrosData.z += accel_err[2] * attitudeSettings.AccelKp / dT + mag_err[2] * attitudeSettings.MagKp / dT;

	// Work out time derivative from INSAlgo writeup
	// Also accounts for the fact that gyros are in deg/s
	float qdot[4];
	qdot[0] = (-q[1] * gyrosData.x - q[2] * gyrosData.y - q[3] * gyrosData.z) * dT * F_PI / 180 / 2;
	qdot[1] = (q[0] * gyrosData.x - q[3] * gyrosData.y + q[2] * gyrosData.z) * dT * F_PI / 180 / 2;
	qdot[2] = (q[3] * gyrosData.x + q[0] * gyrosData.y - q[1] * gyrosData.z) * dT * F_PI / 180 / 2;
	qdot[3] = (-q[2] * gyrosData.x + q[1] * gyrosData.y + q[0] * gyrosData.z) * dT * F_PI / 180 / 2;

	// Take a time step
	q[0] = q[0] + qdot[0];
	q[1] = q[1] + qdot[1];
	q[2] = q[2] + qdot[2];
	q[3] = q[3] + qdot[3];

	if(q[0] < 0) {
		q[0] = -q[0];
		q[1] = -q[1];
		q[2] = -q[2];
		q[3] = -q[3];
	}

	// Renomalize
	qmag = sqrtf(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
	q[0] = q[0] / qmag;
	q[1] = q[1] / qmag;
	q[2] = q[2] / qmag;
	q[3] = q[3] / qmag;

	// If quaternion has become inappropriately short or is nan reinit.
	// THIS SHOULD NEVER ACTUALLY HAPPEN
	if((fabs(qmag) < 1.0e-3f) || (qmag != qmag)) {
		q[0] = 1;
		q[1] = 0;
		q[2] = 0;
		q[3] = 0;
	}

	quat_copy(q, &attitudeActual.q1);

	// Convert into eueler degrees (makes assumptions about RPY order)
	Quaternion2RPY(&attitudeActual.q1,&attitudeActual.Roll);

	AttitudeActualSet(&attitudeActual);

	// Flush these queues for avoid errors
	xQueueReceive(baroQueue, &ev, 0);
	if ( xQueueReceive(gpsQueue, &ev, 0) == pdTRUE && homeLocation.Set == HOMELOCATION_SET_TRUE ) {
		float NED[3];
		// Transform the GPS position into NED coordinates
		GPSPositionData gpsPosition;
		GPSPositionGet(&gpsPosition);
		getNED(&gpsPosition, NED);
		
		NEDPositionData nedPosition;
		NEDPositionGet(&nedPosition);
		nedPosition.North = NED[0];
		nedPosition.East = NED[1];
		nedPosition.Down = NED[2];
		NEDPositionSet(&nedPosition);

		PositionActualData positionActual;
		PositionActualGet(&positionActual);
		positionActual.North = NED[0];
		positionActual.East = NED[1];
		positionActual.Down = NED[2];
		PositionActualSet(&positionActual);
	}

	if ( xQueueReceive(gpsVelQueue, &ev, 0) == pdTRUE ) {
		// Transform the GPS position into NED coordinates
		GPSVelocityData gpsVelocity;
		GPSVelocityGet(&gpsVelocity);

		VelocityActualData velocityActual;
		VelocityActualGet(&velocityActual);
		velocityActual.North = gpsVelocity.North;
		velocityActual.East = gpsVelocity.East;
		velocityActual.Down = gpsVelocity.Down;
		VelocityActualSet(&velocityActual);
	}


	AlarmsClear(SYSTEMALARMS_ALARM_ATTITUDE);

	return 0;
}

/**
 * If accumulating data and enough samples acquired then recompute
 * the gyro bias based on the mean accumulated
 */
static void accumulate_gyro_compute()
{
	if (gyro_bias_estimation.accumulating_gyro && 
		gyro_bias_estimation.accumulated_gyro_samples > 100) {

		// Accumulate integral of error.  Scale here so that units are (deg/s) but Ki has units of s
		GyrosBiasData gyrosBias;
		GyrosBiasGet(&gyrosBias);
		gyrosBias.x = gyro_bias_estimation.accumulated_gyro[0] / gyro_bias_estimation.accumulated_gyro_samples;
		gyrosBias.y = gyro_bias_estimation.accumulated_gyro[1] / gyro_bias_estimation.accumulated_gyro_samples;
		gyrosBias.z = gyro_bias_estimation.accumulated_gyro[2] / gyro_bias_estimation.accumulated_gyro_samples;
		GyrosBiasSet(&gyrosBias);

		accumulate_gyro_zero();

		gyro_bias_estimation.accumulating_gyro = false;
	}
}

/**
 * Zero the accumulation of gyro data
 */
static void accumulate_gyro_zero()
{
	gyro_bias_estimation.accumulated_gyro_samples = 0;
	gyro_bias_estimation.accumulated_gyro[0] = 0;
	gyro_bias_estimation.accumulated_gyro[1] = 0;
	gyro_bias_estimation.accumulated_gyro[2] = 0;
}

/**
 * Accumulate a set of gyro samples for computing the
 * bias
 * @param [in] gyrosData The samples of data to accumulate
 */
static void accumulate_gyro(GyrosData *gyrosData)
{
	if (!gyro_bias_estimation.accumulating_gyro)
		return;

	gyro_bias_estimation.accumulated_gyro_samples++;

	// bias_correct_gyro
	if (true) {
		// Apply bias correction to the gyros from the state estimator
		GyrosBiasData gyrosBias;
		GyrosBiasGet(&gyrosBias);

		gyro_bias_estimation.accumulated_gyro[0] += gyrosData->x + gyrosBias.x;
		gyro_bias_estimation.accumulated_gyro[1] += gyrosData->y + gyrosBias.y;
		gyro_bias_estimation.accumulated_gyro[2] += gyrosData->z + gyrosBias.z;
	} else {
		gyro_bias_estimation.accumulated_gyro[0] += gyrosData->x;
		gyro_bias_estimation.accumulated_gyro[1] += gyrosData->y;
		gyro_bias_estimation.accumulated_gyro[2] += gyrosData->z;
	}
}


#include "insgps.h"
int32_t ins_failed = 0;
int32_t init_stage = 0;

/**
 * @brief Use the INSGPS fusion algorithm in either indoor or outdoor mode (use GPS)
 * @params[in] first_run This is the first run so trigger reinitialization
 * @params[in] outdoor_mode If true use the GPS for position, if false weakly pull to (0,0)
 * @return 0 for success, -1 for failure
 */
static int32_t updateAttitudeINSGPS(bool first_run, bool outdoor_mode)
{
	UAVObjEvent ev;
	GyrosData gyrosData;
	AccelsData accelsData;
	MagnetometerData magData;
	BaroAltitudeData baroData;
	GPSPositionData gpsData;
	GPSVelocityData gpsVelData;
	GyrosBiasData gyrosBias;

	struct NavStruct *Nav = INSGPSGetNav();
	if (Nav == NULL)
		return -1;

	static bool mag_updated = false;
	static bool baro_updated;
	static bool gps_updated;
	static bool gps_vel_updated;

	static float baroOffset = 0;

	static uint32_t ins_last_time = 0;
	static bool inited;

	float NED[3] = {0.0f, 0.0f, 0.0f};
	float vel[3] = {0.0f, 0.0f, 0.0f};
	float zeros[3] = {0.0f, 0.0f, 0.0f};

	// Perform the update
	uint16_t sensors = 0;
	float dT;

	// Wait until the gyro and accel object is updated, if a timeout then go to failsafe
	if ( (xQueueReceive(gyroQueue, &ev, FAILSAFE_TIMEOUT_MS / portTICK_RATE_MS) != pdTRUE) ||
	     (xQueueReceive(accelQueue, &ev, 1 / portTICK_RATE_MS) != pdTRUE) )
	{
		// Do not set attitude timeout warnings in simulation mode
		if (!AttitudeActualReadOnly()){
			AlarmsSet(SYSTEMALARMS_ALARM_ATTITUDE,SYSTEMALARMS_ALARM_WARNING);
			return -1;
		}
	}

	if (inited) {
		mag_updated = 0;
		baro_updated = 0;
		gps_updated = 0;
		gps_vel_updated = 0;
	}

	if (first_run) {
		inited = false;
		init_stage = 0;

		mag_updated = 0;
		baro_updated = 0;
		gps_updated = 0;
		gps_vel_updated = 0;

		ins_last_time = PIOS_DELAY_GetRaw();

		return 0;
	}

	mag_updated |= (xQueueReceive(magQueue, &ev, 0 / portTICK_RATE_MS) == pdTRUE);
	baro_updated |= xQueueReceive(baroQueue, &ev, 0 / portTICK_RATE_MS) == pdTRUE;
	gps_updated |= (xQueueReceive(gpsQueue, &ev, 0 / portTICK_RATE_MS) == pdTRUE) && outdoor_mode;
	gps_vel_updated |= (xQueueReceive(gpsVelQueue, &ev, 0 / portTICK_RATE_MS) == pdTRUE) && outdoor_mode;

	// Get most recent data
	GyrosGet(&gyrosData);
	AccelsGet(&accelsData);
	MagnetometerGet(&magData);
	BaroAltitudeGet(&baroData);
	GPSPositionGet(&gpsData);
	GPSVelocityGet(&gpsVelData);
	GyrosBiasGet(&gyrosBias);

	// Discard mag if it has NAN (normally from bad calibration)
	mag_updated &= (magData.x == magData.x && magData.y == magData.y && magData.z == magData.z);
	// Don't require HomeLocation.Set to be true but at least require a mag configuration (allows easily
	// switching between indoor and outdoor mode with Set = false)
	mag_updated &= (homeLocation.Be[0] != 0 || homeLocation.Be[1] != 0 || homeLocation.Be[2]);

	// Have a minimum requirement for gps usage
	gps_updated &= (gpsData.Satellites >= 7) && (gpsData.PDOP <= 4.0f) && (homeLocation.Set == HOMELOCATION_SET_TRUE);

	if (!inited)
		AlarmsSet(SYSTEMALARMS_ALARM_ATTITUDE,SYSTEMALARMS_ALARM_ERROR);
	else if (outdoor_mode && gpsData.Satellites < 7)
		AlarmsSet(SYSTEMALARMS_ALARM_ATTITUDE,SYSTEMALARMS_ALARM_ERROR);
	else
		AlarmsClear(SYSTEMALARMS_ALARM_ATTITUDE);
			
	if (!inited && mag_updated && baro_updated && (gps_updated || !outdoor_mode)) {
		// Don't initialize until all sensors are read
		if (init_stage == 0 && !outdoor_mode) {
			float Pdiag[16]={25.0f,25.0f,25.0f,5.0f,5.0f,5.0f,1e-5f,1e-5f,1e-5f,1e-5f,1e-5f,1e-5f,1e-5f,1e-4f,1e-4f,1e-4f};
			float q[4];
			float pos[3] = {0.0f, 0.0f, 0.0f};

			// Initialize barometric offset to homelocation altitude
			baroOffset = -baroData.Altitude;
			pos[2] = -(baroData.Altitude + baroOffset);

			// Reset the INS algorithm
			INSGPSInit();
			INSSetMagVar(insSettings.mag_var);
			INSSetAccelVar(insSettings.accel_var);
			INSSetGyroVar(insSettings.gyro_var);
			INSSetBaroVar(insSettings.baro_var);

			// Initialize the gyro bias from the settings
			float gyro_bias[3] = {gyrosBias.x * F_PI / 180.0f, gyrosBias.y * F_PI / 180.0f, gyrosBias.z * F_PI / 180.0f};
			INSSetGyroBias(gyro_bias);

			xQueueReceive(magQueue, &ev, 100 / portTICK_RATE_MS);
			MagnetometerGet(&magData);

			// Set initial attitude
			AttitudeActualData attitudeActual;
			attitudeActual.Roll = atan2f(-accelsData.y, -accelsData.z) * 180.0f / F_PI;
			attitudeActual.Pitch = atan2f(accelsData.x, -accelsData.z) * 180.0f / F_PI;
			attitudeActual.Yaw = atan2f(-magData.y, magData.x) * 180.0f / F_PI;
			RPY2Quaternion(&attitudeActual.Roll,&attitudeActual.q1);
			AttitudeActualSet(&attitudeActual);

			q[0] = attitudeActual.q1;
			q[1] = attitudeActual.q2;
			q[2] = attitudeActual.q3;
			q[3] = attitudeActual.q4;
			INSSetState(pos, zeros, q, zeros, zeros);
			INSResetP(Pdiag);
		} else if (init_stage == 0 && outdoor_mode) {
			float Pdiag[16]={25.0f,25.0f,25.0f,5.0f,5.0f,5.0f,1e-5f,1e-5f,1e-5f,1e-5f,1e-5f,1e-5f,1e-5f,1e-4f,1e-4f,1e-4f};
			float q[4];
			float NED[3];

			// Reset the INS algorithm
			INSGPSInit();
			INSSetMagVar(insSettings.mag_var);
			INSSetAccelVar(insSettings.accel_var);
			INSSetGyroVar(insSettings.gyro_var);
			INSSetBaroVar(insSettings.baro_var);

			INSSetMagNorth(homeLocation.Be);

			// Initialize the gyro bias from the settings
			float gyro_bias[3] = {gyrosBias.x * F_PI / 180.0f, gyrosBias.y * F_PI / 180.0f, gyrosBias.z * F_PI / 180.0f};
			INSSetGyroBias(gyro_bias);

			GPSPositionData gpsPosition;
			GPSPositionGet(&gpsPosition);

			// Transform the GPS position into NED coordinates
			getNED(&gpsPosition, NED);
			
			// Initialize barometric offset to cirrent GPS NED coordinate
			baroOffset = -NED[2] - baroData.Altitude;

			xQueueReceive(magQueue, &ev, 100 / portTICK_RATE_MS);
			MagnetometerGet(&magData);

			// Set initial attitude
			AttitudeActualData attitudeActual;
			attitudeActual.Roll = atan2f(-accelsData.y, -accelsData.z) * 180.0f / F_PI;
			attitudeActual.Pitch = atan2f(accelsData.x, -accelsData.z) * 180.0f / F_PI;
			attitudeActual.Yaw = atan2f(-magData.y, magData.x) * 180.0f / F_PI;
			RPY2Quaternion(&attitudeActual.Roll,&attitudeActual.q1);
			AttitudeActualSet(&attitudeActual);

			q[0] = attitudeActual.q1;
			q[1] = attitudeActual.q2;
			q[2] = attitudeActual.q3;
			q[3] = attitudeActual.q4;

			INSSetState(NED, zeros, q, zeros, zeros);
			INSResetP(Pdiag);
		} else if (init_stage > 0) {
			// Run prediction a bit before any corrections
			dT = PIOS_DELAY_DiffuS(ins_last_time) / 1.0e6f;

			GyrosBiasGet(&gyrosBias);
			float gyros[3] = {(gyrosData.x + gyrosBias.x) * F_PI / 180.0f, 
				(gyrosData.y + gyrosBias.y) * F_PI / 180.0f, 
				(gyrosData.z + gyrosBias.z) * F_PI / 180.0f};
			INSStatePrediction(gyros, &accelsData.x, dT);
			
			AttitudeActualData attitude;
			AttitudeActualGet(&attitude);
			attitude.q1 = Nav->q[0];
			attitude.q2 = Nav->q[1];
			attitude.q3 = Nav->q[2];
			attitude.q4 = Nav->q[3];
			Quaternion2RPY(&attitude.q1,&attitude.Roll);
			AttitudeActualSet(&attitude);
		}

		init_stage++;
		if(init_stage > 10)
			inited = true;

		ins_last_time = PIOS_DELAY_GetRaw();	

		return 0;
	}

	if (!inited)
		return 0;

	dT = PIOS_DELAY_DiffuS(ins_last_time) / 1.0e6f;
	ins_last_time = PIOS_DELAY_GetRaw();

	// This should only happen at start up or at mode switches
	if(dT > 0.01f)
		dT = 0.01f;
	else if(dT <= 0.001f)
		dT = 0.001f;

	// If the gyro bias setting was updated we should reset
	// the state estimate of the EKF
	if(gyroBiasSettingsUpdated) {
		float gyro_bias[3] = {gyrosBias.x * F_PI / 180.0f, gyrosBias.y * F_PI / 180.0f, gyrosBias.z * F_PI / 180.0f};
		INSSetGyroBias(gyro_bias);
		gyroBiasSettingsUpdated = false;
	}

	// Because the sensor module remove the bias we need to add it
	// back in here so that the INS algorithm can track it correctly
	float gyros[3] = {gyrosData.x * F_PI / 180.0f, gyrosData.y * F_PI / 180.0f, gyrosData.z * F_PI / 180.0f};
	if (attitudeSettings.BiasCorrectGyro == ATTITUDESETTINGS_BIASCORRECTGYRO_TRUE) {
		gyros[0] += gyrosBias.x * F_PI / 180.0f;
		gyros[1] += gyrosBias.y * F_PI / 180.0f;
		gyros[2] += gyrosBias.z * F_PI / 180.0f;
	}

	// Advance the state estimate
	INSStatePrediction(gyros, &accelsData.x, dT);

	// Copy the attitude into the UAVO
	AttitudeActualData attitude;
	AttitudeActualGet(&attitude);
	attitude.q1 = Nav->q[0];
	attitude.q2 = Nav->q[1];
	attitude.q3 = Nav->q[2];
	attitude.q4 = Nav->q[3];
	Quaternion2RPY(&attitude.q1,&attitude.Roll);
	AttitudeActualSet(&attitude);

	// Advance the covariance estimate
	INSCovariancePrediction(dT);

	if(mag_updated)
		sensors |= MAG_SENSORS;

	if(baro_updated)
		sensors |= BARO_SENSOR;

	INSSetMagNorth(homeLocation.Be);
	
	if (gps_updated && outdoor_mode)
	{
		INSSetPosVelVar(insSettings.gps_var[INSSETTINGS_GPS_VAR_POS], insSettings.gps_var[INSSETTINGS_GPS_VAR_VEL]);
		sensors |= POS_SENSORS;

		if (0) { // Old code to take horizontal velocity from GPS Position update
			sensors |= HORIZ_SENSORS;
			vel[0] = gpsData.Groundspeed * cosf(gpsData.Heading * F_PI / 180.0f);
			vel[1] = gpsData.Groundspeed * sinf(gpsData.Heading * F_PI / 180.0f);
			vel[2] = 0;
		}
		// Transform the GPS position into NED coordinates
		getNED(&gpsData, NED);

		// Track barometric altitude offset with a low pass filter
		baroOffset = BARO_OFFSET_LOWPASS_ALPHA * baroOffset +
		    (1.0f - BARO_OFFSET_LOWPASS_ALPHA )
		    * ( -NED[2] - baroData.Altitude );

		// Store this for inspecting offline
		NEDPositionData nedPos;
		NEDPositionGet(&nedPos);
		nedPos.North = NED[0];
		nedPos.East = NED[1];
		nedPos.Down = NED[2];
		NEDPositionSet(&nedPos);

	} else if (!outdoor_mode) {
		baroOffset = 0;
		INSSetPosVelVar(1e2f, 1e2f);
		vel[0] = vel[1] = vel[2] = 0;
		NED[0] = NED[1] = 0;
		NED[2] = -(baroData.Altitude + baroOffset);
		sensors |= HORIZ_SENSORS | HORIZ_POS_SENSORS;
		sensors |= POS_SENSORS |VERT_SENSORS;
	}

	if (gps_vel_updated && outdoor_mode) {
		sensors |= HORIZ_SENSORS | VERT_SENSORS;
		vel[0] = gpsVelData.North;
		vel[1] = gpsVelData.East;
		vel[2] = gpsVelData.Down;
	}
	
	/*
	 * TODO: Need to add a general sanity check for all the inputs to make sure their kosher
	 * although probably should occur within INS itself
	 */
	if (sensors)
		INSCorrection(&magData.x, NED, vel, ( baroData.Altitude + baroOffset ), sensors);

	// Copy the position and velocity into the UAVO
	PositionActualData positionActual;
	PositionActualGet(&positionActual);
	positionActual.North = Nav->Pos[0];
	positionActual.East = Nav->Pos[1];
	positionActual.Down = Nav->Pos[2];
	PositionActualSet(&positionActual);
	
	VelocityActualData velocityActual;
	VelocityActualGet(&velocityActual);
	velocityActual.North = Nav->Vel[0];
	velocityActual.East = Nav->Vel[1];
	velocityActual.Down = Nav->Vel[2];
	VelocityActualSet(&velocityActual);

	if (attitudeSettings.BiasCorrectGyro == ATTITUDESETTINGS_BIASCORRECTGYRO_TRUE && !gyroBiasSettingsUpdated) {
		// Copy the gyro bias into the UAVO except when it was updated
		// from the settings during the calculation, then consume it
		// next cycle
		gyrosBias.x = Nav->gyro_bias[0] * 180.0f / F_PI;
		gyrosBias.y = Nav->gyro_bias[1] * 180.0f / F_PI;
		gyrosBias.z = Nav->gyro_bias[2] * 180.0f / F_PI;
		GyrosBiasSet(&gyrosBias);
	}

	return 0;
}

static void apply_accel_filter(const float * raw, float * filtered)
{
	if(accel_filter_enabled) {
		filtered[0] = filtered[0] * accel_alpha + raw[0] * (1 - accel_alpha);
		filtered[1] = filtered[1] * accel_alpha + raw[1] * (1 - accel_alpha);
		filtered[2] = filtered[2] * accel_alpha + raw[2] * (1 - accel_alpha);
	} else {
		filtered[0] = raw[0];
		filtered[1] = raw[1];
		filtered[2] = raw[2];
	}
}

/**
 * @brief Convert the GPS LLA position into NED coordinates
 * @note this method uses a taylor expansion around the home coordinates
 * to convert to NED which allows it to be done with all floating
 * calculations
 * @param[in] Current GPS coordinates
 * @param[out] NED frame coordinates
 * @returns 0 for success, -1 for failure
 */
float T[3];
const float DEG2RAD = 3.141592653589793f / 180.0f;
static int32_t getNED(GPSPositionData * gpsPosition, float * NED)
{
	float dL[3] = {(gpsPosition->Latitude - homeLocation.Latitude) / 10.0e6f * DEG2RAD,
		(gpsPosition->Longitude - homeLocation.Longitude) / 10.0e6f * DEG2RAD,
		(gpsPosition->Altitude + gpsPosition->GeoidSeparation - homeLocation.Altitude)};

	NED[0] = T[0] * dL[0];
	NED[1] = T[1] * dL[1];
	NED[2] = T[2] * dL[2];

	return 0;
}

static void settingsUpdatedCb(UAVObjEvent * ev) 
{
	if (ev == NULL || ev->obj == InertialSensorSettingsHandle()) {
		InertialSensorSettingsData inertialSensorSettings;
		InertialSensorSettingsGet(&inertialSensorSettings);
		
		/* When the revo calibration is updated, update the GyroBias object */
		GyrosBiasData gyrosBias;
		GyrosBiasGet(&gyrosBias);
		gyrosBias.x = inertialSensorSettings.InitialGyroBias[INERTIALSENSORSETTINGS_INITIALGYROBIAS_X];
		gyrosBias.y = inertialSensorSettings.InitialGyroBias[INERTIALSENSORSETTINGS_INITIALGYROBIAS_Y];
		gyrosBias.z = inertialSensorSettings.InitialGyroBias[INERTIALSENSORSETTINGS_INITIALGYROBIAS_Z];
		GyrosBiasSet(&gyrosBias);

		gyroBiasSettingsUpdated = true;
	}
	if (ev == NULL || ev->obj == INSSettingsHandle()) {
		INSSettingsGet(&insSettings);
		// In case INS currently running
		INSSetMagVar(insSettings.mag_var);
		INSSetAccelVar(insSettings.accel_var);
		INSSetGyroVar(insSettings.gyro_var);
		INSSetBaroVar(insSettings.baro_var);
	}
	if(ev == NULL || ev->obj == HomeLocationHandle()) {
		HomeLocationGet(&homeLocation);
		// Compute matrix to convert deltaLLA to NED
		float lat, alt;
		lat = homeLocation.Latitude / 10.0e6f * DEG2RAD;
		alt = homeLocation.Altitude;

		T[0] = alt+6.378137E6f;
		T[1] = cosf(lat)*(alt+6.378137E6f);
		T[2] = -1.0f;
	}
	if (ev == NULL || ev->obj == AttitudeSettingsHandle()) {
		AttitudeSettingsGet(&attitudeSettings);
			
		// Calculate accel filter alpha, in the same way as for gyro data in stabilization module.
		const float fakeDt = 0.0025;
		if(attitudeSettings.AccelTau < 0.0001) {
			accel_alpha = 0;   // not trusting this to resolve to 0
			accel_filter_enabled = false;
		} else {
			accel_alpha = expf(-fakeDt  / attitudeSettings.AccelTau);
			accel_filter_enabled = true;
		}
	}
	if (ev == NULL || ev->obj == RevoSettingsHandle())
		RevoSettingsGet(&revoSettings);
}
/**
 * @}
 * @}
 */
