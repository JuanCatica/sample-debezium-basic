# OJO: Esta Joda no tiene uso de patrones

import time
import json
import math
from collections import deque

import boto3
import pandas as pd
import awswrangler as wr
from sqlalchemy import create_engine, text, bindparam
from tqdm import tqdm

# ----------------------
# SQLLoader Class
# ----------------------
class SQLLoader:
    """
    
    """
    AVAILABLE = "AVAILABLE"
    STOPPED = "STOPPED"
    RUNNING = "RUNNING"
    DESTROYED = "DESTOYED"
    
    def __init__(self, dbengine, dbhost, dbuser, dbpass, dbport, dbname, dbtable, dtype_db=None):
        """
        Initialize the loader.
        """
        self.engine = create_engine(f'{dbengine}://{dbuser}:{dbpass}@{dbhost}:{dbport}/{dbname}')
        self.dbtable = dbtable
        self.dtype_db = dtype_db or {}
        
        self.iteration = 0
        self.registers_inserted = 0
        self.registers_updated = 0
        self.registers_deleted = 0
        self.start_time = None
        
        self.__status = {
            "state": self.AVAILABLE,
            "iteration":self.iteration,
            "inserted":self.registers_inserted,
            "updated":self.registers_updated,
            "deleted":self.registers_deleted,
            "indb":0
        }

    def load_file(self, file, dtype={}, date_fields=[]):
        """
        Load a new file into the loader.
        """
        self.file = file
        self.df = pd.read_csv(f"{self.file}",dtype=dtype, parse_dates=date_fields)
        if "tag" in self.df.columns:
            self.df = self.df[self.df["tag"].astype(str).str.len() <= 90]
        
        self.df["_insert"] = 0
        self.df["_insert_time"] = 0
        self.df["_update"] = 0
        self.df["_update_time"] = 0
        self.df["_delete"] = 0
        self.df["_delete_time"] = 0

    def enable_cdc_supplemental_logging(self):
        """
        Enable supplemental logging on Oracle RDS for CDC (Change Data Capture).
        Required for Debezium/Oracle CDC to capture before/after values.
        """
        plsql_config = """
            begin
                rdsadmin.rdsadmin_util.force_logging(p_enable => true);
                rdsadmin.rdsadmin_util.alter_supplemental_logging(p_action => 'ADD');
                rdsadmin.rdsadmin_util.alter_supplemental_logging(p_action => 'ADD',p_type => 'ALL');
                rdsadmin.rdsadmin_util.alter_supplemental_logging(p_action => 'ADD',p_type => 'PRIMARY KEY');
                rdsadmin.rdsadmin_util.switch_logfile;
                rdsadmin.rdsadmin_master_util.create_archivelog_dir;
                rdsadmin.rdsadmin_master_util.create_onlinelog_dir;
            end;
        """
        with self.engine.begin() as conn:
            conn.execute(text(plsql_config))
        print("CDC supplemental logging enabled successfully.")

    def check_supplemental_logging(self):
        """
        Check if supplemental logging is enabled.
        SELECT SUPPLEMENTAL_LOG_DATA_MIN, SUPPLEMENTAL_LOG_DATA_ALL FROM V$DATABASE;
        """
        with self.engine.begin() as conn:
            result = conn.execute(text("SELECT SUPPLEMENTAL_LOG_DATA_MIN, SUPPLEMENTAL_LOG_DATA_ALL FROM v$database"))
            row = result.fetchone()
            supplemental_logging_min = row[0]
            supplemental_logging_all = row[1]
        return {
            "supplemental_logging_min": supplemental_logging_min,
            "supplemental_logging_all": supplemental_logging_all
        }
        
    def __get_message(self, in_db="", i="", u="", d="", i_s="", u_s="", d_s="", loop_perc="", db_perc=""):
        state = self.__status["state"]
        play = "" if state != self.RUNNING else "▶" if self.iteration%2==0 else "·" 
        
        state_db = f"{play}[{state}] DB:{in_db}"
        uid = f"I:{i}, U:{u}, D:{d}"
        uid_s = f"I/s:{i_s:.0f}, U/s:{u_s:.0f}, D/s:{d_s:.0f}"
        percent = f"Loop:{loop_perc:.2f}%, DF:{db_perc:.2f}%"
        run_time = f"Run Time: {time.time() - self.start_time:.2f}s"    
        
        message = f"{state_db} | {uid} | {uid_s} | {percent} | {run_time}"
        return message
    
    def __printUI(self, message):
        print(message, end="\r", flush=True)
    
    def insert(self, registers=10, delay=0):
        """
        
        """
        temp_df = self.df.iloc[self.registers_inserted : self.registers_inserted + registers].copy()
        temp_df["_insert"] = 1        
        temp_df["_insert_time"] = time.time()
        temp_df.drop(["_delete","_delete_time"],axis=1).to_sql(
            name=self.dbtable,
            con=self.engine,
            if_exists="append",
            dtype=self.dtype_db
        )
        self.df.iloc[self.registers_inserted : self.registers_inserted + registers] = temp_df
        self.registers_inserted += registers
        time.sleep(delay)
    
    def update(self, registers=5, delay=0):
        """
        
        """
        if registers > 0:
            temp_df = self.df.iloc[:self.registers_inserted][self.df._delete==0].sample(n=registers).copy()
            temp_df["_update"] = temp_df["_update"] + 1
            temp_df["_update_time"] = time.time()

            indexes_str = map(lambda x: str(x), temp_df.index.to_list())
            indexes = ",".join(indexes_str)
            with self.engine.begin() as conn:
                conn.execute(text(f"""
                    UPDATE {self.dbtable}
                    SET "_update" = "_update" + 1, "_update_time" = {time.time()}
                    WHERE "idx" IN ({indexes})
                """))
            self.df[self.df.index.isin(temp_df.index)] = temp_df.copy()
            self.registers_updated += len(temp_df)
            time.sleep(delay)
    
    def delete(self, registers=1, delay=0):
        """
        
        """
        if registers > 0:
            temp_df = self.df.iloc[:self.registers_inserted][self.df._delete==0].sample(n=registers).copy()
            temp_df["_delete"] = temp_df["_delete"] + 1
            temp_df["_delete_time"] = time.time()

            indexes_str = map(lambda x: str(x), temp_df.index.to_list())
            indexes = ",".join(indexes_str)
            with self.engine.begin() as conn:
                conn.execute(text(f"""
                    DELETE FROM {self.dbtable}
                    WHERE "idx" IN ({indexes})
                """))
            self.df[self.df.index.isin(temp_df.index)] = temp_df.copy()
            self.registers_deleted += len(temp_df)
            time.sleep(delay)

    def iud(self, inserts=10, updates=5, deletes=0, delay=0, max_registers=None, uix=False):
        """
        
        """     
        # VALIDATIONS
        # if self.__status["state"] == self.RUNNING or self.__status["state"] == self.STOPPED:
        #     print("There is already a 'iudx' load in progress, please destroy the process.")
        #     return
        assert inserts > 0, "'inserts' must be grather than 0."
        assert inserts > deletes, "'inserts' must be grather than 'deletes'."
        
        # INITIATING STATE AND VARS
        self.__status["state"] = self.RUNNING
        message = ""
        in_db = None
        inserted = None
        updated = None
        deleted = None
        i_s = None
        u_s = None
        d_s = None
        loop_perc = None
        df_perc = None
        
        # CALCULATING ITERATIONS
        not_inserted = len(self.df[self.df["_insert"]==0])
        max_registers = max_registers if max_registers else not_inserted
        num_iters = math.ceil(min(max_registers/float(inserts), not_inserted/float(inserts)))
        iterations = range(num_iters) if uix else tqdm(range(num_iters))

        # SET START TIME
        self.start_time = time.time()
        
        # MAIN LOOP
        for i in iterations:            
            start = time.time()
            
            # INERTS | UPDATE | DELETES
            self.insert(inserts)
            self.update(updates)
            self.delete(deletes)
            
            # QUERY STATUS AND DELAY
            st = self.status()
            time.sleep(delay)
            delta = float(time.time() - start)
            
            # PROCESS STATS
            in_db = st["indb"]
            inserted = st["inserted"]
            updated = st["updated"]
            deleted = st["deleted"] 
            i_s = inserts/delta
            u_s = updates/delta
            d_s = deletes/delta
            loop_perc = 100.0*i/float(num_iters)
            df_perc = 100.0*self.registers_inserted/len(self.df)
            self.iteration +=1
            
            # MESSAGE
            message = self.__get_message(in_db, inserted, updated, deleted, i_s, u_s, d_s, loop_perc, df_perc)
            
            # PRINT MESSAGE: TQDM | UI WIDGETS
            if uix==False:
                iterations.set_description(message)
            else:
                self.__printUI(message)
                
        # LAST MESSAGE
        self.__status["state"] = self.AVAILABLE
        message = self.__get_message(in_db, inserted, updated, deleted, i_s, u_s, d_s, loop_perc, df_perc)
        print(message)
    
    def iudx(self, inserts=10, updates=5, deletes=0, delay=0):
        """
        
        """
        # if self.__status["state"] == self.RUNNING or self.__status["state"] == self.STOPPED:
        #     print("There is already a 'iudx' load in progress")
        # else:
        self.iud(inserts, updates, deletes, delay, None, True)

    def status(self):
        """
        
        """
        try:
            with self.engine.connect() as conn:
                result = conn.execute(text(f'SELECT COUNT(*) FROM {self.dbtable}'))
                registers_in_db = result.scalar()
        except:
            registers_in_db = None     
        self.__status["iteration"] = self.iteration
        self.__status["inserted"] = self.registers_inserted
        self.__status["updated"] = self.registers_updated
        self.__status["deleted"] = self.registers_deleted
        self.__status["indb"] = registers_in_db
        return self.__status
        
    def drop_table(self):
        """
        
        """
        self.iteration = 0
        self.registers_inserted = 0
        self.registers_updated = 0
        self.registers_deleted = 0
        
        try:
            with self.engine.begin() as conn:
                conn.execute(text(f'SELECT COUNT(*) FROM {self.dbtable}'))
                conn.execute(text(f'DROP TABLE {self.dbtable}'))
        except:
            print(f"Error dropping table {self.dbtable}.")
            pass